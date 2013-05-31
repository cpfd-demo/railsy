require 'active_support/core_ext/object/try'
require 'active_support/core_ext/kernel/singleton_class'
require 'action_view/compiler'
require 'thread'

module ActionView
  # = Action View Template
  class Template
    extend ActiveSupport::Autoload

    # === Encodings in ActionView::Template
    #
    # ActionView::Template is one of a few sources of potential
    # encoding issues in Rails. This is because the source for
    # templates are usually read from disk, and Ruby (like most
    # encoding-aware programming languages) assumes that the
    # String retrieved through File IO is encoded in the
    # <tt>default_external</tt> encoding. In Rails, the default
    # <tt>default_external</tt> encoding is UTF-8.
    #
    # As a result, if a user saves their template as ISO-8859-1
    # (for instance, using a non-Unicode-aware text editor),
    # and uses characters outside of the ASCII range, their
    # users will see diamonds with question marks in them in
    # the browser.
    #
    # For the rest of this documentation, when we say "UTF-8",
    # we mean "UTF-8 or whatever the default_internal encoding
    # is set to". By default, it will be UTF-8.
    #
    # To mitigate this problem, we use a few strategies:
    # 1. If the source is not valid UTF-8, we raise an exception
    #    when the template is compiled to alert the user
    #    to the problem.
    # 2. The user can specify the encoding using Ruby-style
    #    encoding comments in any template engine. If such
    #    a comment is supplied, Rails will apply that encoding
    #    to the resulting compiled source returned by the
    #    template handler.
    # 3. In all cases, we transcode the resulting String to
    #    the UTF-8.
    #
    # This means that other parts of Rails can always assume
    # that templates are encoded in UTF-8, even if the original
    # source of the template was not UTF-8.
    #
    # From a user's perspective, the easiest thing to do is
    # to save your templates as UTF-8. If you do this, you
    # do not need to do anything else for things to "just work".
    #
    # === Instructions for template handlers
    #
    # The easiest thing for you to do is to simply ignore
    # encodings. Rails will hand you the template source
    # as the default_internal (generally UTF-8), raising
    # an exception for the user before sending the template
    # to you if it could not determine the original encoding.
    #
    # For the greatest simplicity, you can support only
    # UTF-8 as the <tt>default_internal</tt>. This means
    # that from the perspective of your handler, the
    # entire pipeline is just UTF-8.
    #
    # === Advanced: Handlers with alternate metadata sources
    #
    # If you want to provide an alternate mechanism for
    # specifying encodings (like ERB does via <%# encoding: ... %>),
    # you may indicate that you will handle encodings yourself
    # by implementing <tt>self.handles_encoding?</tt>
    # on your handler.
    #
    # If you do, Rails will not try to encode the String
    # into the default_internal, passing you the unaltered
    # bytes tagged with the assumed encoding (from
    # default_external).
    #
    # In this case, make sure you return a String from
    # your handler encoded in the default_internal. Since
    # you are handling out-of-band metadata, you are
    # also responsible for alerting the user to any
    # problems with converting the user's data to
    # the <tt>default_internal</tt>.
    #
    # To do so, simply raise +WrongEncodingError+ as follows:
    #
    #     raise WrongEncodingError.new(
    #       problematic_string,
    #       expected_encoding
    #     )

    eager_autoload do
      autoload :Error
      autoload :Handlers
      autoload :Text
      autoload :Types
    end

    extend Template::Handlers

    attr_accessor :locals, :formats, :virtual_path

    attr_reader :source, :identifier, :handler, :original_encoding, :updated_at

    # This finalizer is needed (and exactly with a proc inside another proc)
    # otherwise templates leak in development.
    Finalizer = proc do |method_name, mod|
      proc do
        mod.module_eval do
          remove_possible_method method_name
        end
      end
    end

    def initialize(source, identifier, handler, details)
      format = details[:format] || (handler.default_format if handler.respond_to?(:default_format))

      @source            = source
      @identifier        = identifier
      @handler           = handler
      @compiled          = false
      @original_encoding = nil
      @locals            = details[:locals] || []
      @virtual_path      = details[:virtual_path]
      @updated_at        = details[:updated_at] || Time.now
      @formats           = Array(format).map { |f| f.respond_to?(:ref) ? f.ref : f  }
      @compile_mutex     = Mutex.new
    end

    # Returns if the underlying handler supports streaming. If so,
    # a streaming buffer *may* be passed when it start rendering.
    def supports_streaming?
      handler.respond_to?(:supports_streaming?) && handler.supports_streaming?
    end

    # Render a template. If the template was not compiled yet, it is done
    # exactly before rendering.
    #
    # This method is instrumented as "!render_template.action_view". Notice that
    # we use a bang in this instrumentation because you don't want to
    # consume this in production. This is only slow if it's being listened to.
    def render(view, locals, buffer=nil, &block)
      instrument("!render_template") do
        compiled_template = compile!
        compiled_view = compiled_template.new(view, locals)
        compiled_view.render(buffer, &block)
      end
    rescue Exception => e
      handle_render_error(view, e)
    end

    def mime_type
      message = 'Template#mime_type is deprecated and will be removed in Rails 4.1. Please use type method instead.'
      ActiveSupport::Deprecation.warn message
      @mime_type ||= Mime::Type.lookup_by_extension(@formats.first.to_s) if @formats.first
    end

    def type
      @type ||= Types[@formats.first] if @formats.first
    end

    # Receives a view object and return a template similar to self by using @virtual_path.
    #
    # This method is useful if you have a template object but it does not contain its source
    # anymore since it was already compiled. In such cases, all you need to do is to call
    # refresh passing in the view object.
    #
    # Notice this method raises an error if the template to be refreshed does not have a
    # virtual path set (true just for inline templates).
    def refresh(view)
      raise "A template needs to have a virtual path in order to be refreshed" unless @virtual_path
      lookup  = view.lookup_context
      pieces  = @virtual_path.split("/")
      name    = pieces.pop
      partial = !!name.sub!(/^_/, "")
      lookup.disable_cache do
        lookup.find_template(name, [ pieces.join('/') ], partial, @locals)
      end
    end

    def inspect
      @inspect ||= defined?(Rails.root) ? identifier.sub("#{Rails.root}/", '') : identifier
    end

    # This method is responsible for properly setting the encoding of the
    # source. Until this point, we assume that the source is BINARY data.
    # If no additional information is supplied, we assume the encoding is
    # the same as <tt>Encoding.default_external</tt>.
    #
    # The user can also specify the encoding via a comment on the first
    # line of the template (# encoding: NAME-OF-ENCODING). This will work
    # with any template engine, as we process out the encoding comment
    # before passing the source on to the template engine, leaving a
    # blank line in its stead.
    def encode!
      return unless source.encoding == Encoding::BINARY

      # Look for # encoding: *. If we find one, we'll encode the
      # String in that encoding, otherwise, we'll use the
      # default external encoding.
      if source.sub!(/\A#{ENCODING_FLAG}/, '')
        encoding = magic_encoding = $1
      else
        encoding = Encoding.default_external
      end

      # Tag the source with the default external encoding
      # or the encoding specified in the file
      source.force_encoding(encoding)

      # If the user didn't specify an encoding, and the handler
      # handles encodings, we simply pass the String as is to
      # the handler (with the default_external tag)
      if !magic_encoding && @handler.respond_to?(:handles_encoding?) && @handler.handles_encoding?
        source
      # Otherwise, if the String is valid in the encoding,
      # encode immediately to default_internal. This means
      # that if a handler doesn't handle encodings, it will
      # always get Strings in the default_internal
      elsif source.valid_encoding?
        source.encode!
      # Otherwise, since the String is invalid in the encoding
      # specified, raise an exception
      else
        raise WrongEncodingError.new(source, encoding)
      end
    end

    protected

      # Compile a template. This method ensures a template is compiled
      # just once and removes the source after it is compiled.
      def compile! #:nodoc:
        encode!
        instrument("!compile_template") do
          Compiler.compile_template(self)
        end
      end

      def handle_render_error(view, e) #:nodoc:
        if e.is_a?(Template::Error)
          e.sub_template_of(self)
          raise e
        else
          template = self
          unless template.source
            template = refresh(view)
            template.encode!
          end
          raise Template::Error.new(template, e)
        end
      end

      def locals_code #:nodoc:
        # Double assign to suppress the dreaded 'assigned but unused variable' warning
        @locals.map { |key| "#{key} = #{key} = local_assigns[:#{key}];" }.join
      end

      def method_name #:nodoc:
        @method_name ||= "_#{identifier_method_name}__#{@identifier.hash}_#{__id__}".gsub('-', "_")
      end

      def identifier_method_name #:nodoc:
        inspect.gsub(/[^a-z_]/, '_')
      end

      def instrument(action, &block)
        payload = { virtual_path: @virtual_path, identifier: @identifier }
        ActiveSupport::Notifications.instrument("#{action}.action_view", payload, &block)
      end
  end
end
