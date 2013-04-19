require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/time/zones'
require 'active_model/forbidden_attributes_protection'

module ActiveModel
  # Raised when an error occurred while doing a mass assignment to an attribute
  # through the <tt>attributes=</tt> method. The exception has an +attribute+
  # property that is the name of the offending attribute.
  class AttributeAssignmentError < StandardError
    attr_reader :exception, :attribute
    def initialize(message, exception, attribute)
      super(message)
      @exception = exception
      @attribute = attribute
    end
  end

  # Raised when there are multiple errors while doing a mass assignment through
  # the +attributes=+ method. The exception has an +errors+ property that
  # contains an array of AttributeAssignmentError objects, each corresponding
  # to the error while assigning to an attribute.
  class MultiparameterAssignmentErrors < StandardError
    attr_reader :errors
    def initialize(errors)
      @errors = errors
    end
  end

  # Raised when the +attributes=+ method receives a multi-parameter value for
  # an attribute that isn't expecting one. This either means that the attribute
  # shouldn't have been passed a multi-parameter value because it expects a
  # simple type (like a String), or that the +class_for_attribute+ method needs
  # to be modified to return the correct class for this attribute.
  class UnexpectedMultiparameterValueError < StandardError
  end

  # Raised when unknown attributes are supplied via mass assignment.
  class UnknownAttributeError < NoMethodError
  end

  # == Active \Model Attribute Assignment
  #
  # Provides support for multi-parameter attributes, e.g. date attributes in
  # the format generated by the <tt>date_select</tt> helper.
  #
  # To use <tt>ActiveModel::AttributeAssignment</tt>:
  # * <tt>include ActiveModel::AttributeAssignment</tt> in your object. If you
  #   are also using <tt>ActiveModel::Model</tt> you should include that first.
  # * Define +class_for_attribute+, which should take an attribute name as a
  #   string and return a class for each attribute that should support
  #   multi-parameter values.
  #
  # For example:
  #
  #   class Person
  #     include ActiveModel::AttributeAssignment
  #     attr_accessor :name, :date_of_birth
  #
  #     def class_for_attribute(attr)
  #       if attr == 'date_of_birth'
  #         Date
  #       end
  #     end
  #   end
  #
  #   bob = Person.new(
  #     'name' => 'Bob',
  #     'date_of_birth(1i)' => '1980',
  #     'date_of_birth(2i)' => '1',
  #     'date_of_birth(3i)' => '2'
  #   )
  #   bob.date_of_birth # => #<Date: 1980-01-02>
  #
  # You can pass attributes when constructing a new object, or using the
  # +attributes=+ method.
  module AttributeAssignment
    extend ActiveSupport::Concern
    include ActiveModel::ForbiddenAttributesProtection

    # Initializes a new model with the given +params+.
    #
    #   class Person
    #     include ActiveModel::AttributeAssignment
    #     attr_accessor :name, :age
    #   end
    #
    #   person = Person.new(name: 'bob', age: '18')
    #   person.name # => "bob"
    #   person.age  # => 18
    def initialize(params={})
      assign_attributes(params)
    end

    # Allows you to set all the attributes by passing in a hash of attributes with
    # keys matching the attribute names (which again matches the column names).
    #
    # If the passed hash responds to <tt>permitted?</tt> method and the return value
    # of this method is +false+ an <tt>ActiveModel::ForbiddenAttributesError</tt>
    # exception is raised.
    def assign_attributes(new_attributes)
      if !new_attributes.respond_to?(:stringify_keys)
        raise ArgumentError, "When assigning attributes, you must pass a hash as an argument."
      end
      return if new_attributes.blank?

      attributes                  = new_attributes.stringify_keys
      multi_parameter_attributes  = []
      nested_parameter_attributes = []

      attributes = sanitize_for_mass_assignment(attributes)

      attributes.each do |k, v|
        if k.include?("(")
          multi_parameter_attributes << [ k, v ]
        elsif v.is_a?(Hash)
          nested_parameter_attributes << [ k, v ]
        else
          _assign_attribute(k, v)
        end
      end

      assign_nested_parameter_attributes(nested_parameter_attributes) unless nested_parameter_attributes.empty?
      assign_multiparameter_attributes(multi_parameter_attributes) unless multi_parameter_attributes.empty?
    end

    alias attributes= assign_attributes

    private

    def _assign_attribute(k, v)
      public_send("#{k}=", v)
    rescue NoMethodError
      if respond_to?("#{k}=")
        raise
      else
        raise unknown_attribute_error_class.new(self, k)
      end
    end

    # Assign any deferred nested attributes after the base attributes have been set.
    def assign_nested_parameter_attributes(pairs)
      pairs.each { |k, v| _assign_attribute(k, v) }
    end

    # Instantiates objects for all attribute classes that needs more than one constructor parameter. This is done
    # by calling new on the column type or aggregation type (through composed_of) object with these parameters.
    # So having the pairs written_on(1) = "2004", written_on(2) = "6", written_on(3) = "24", will instantiate
    # written_on (a date type) with Date.new("2004", "6", "24"). You can also specify a typecast character in the
    # parentheses to have the parameters typecasted before they're used in the constructor. Use i for Fixnum and
    # f for Float. If all the values for a given attribute are empty, the attribute will be set to +nil+.
    def assign_multiparameter_attributes(pairs)
      execute_callstack_for_multiparameter_attributes(
        extract_callstack_for_multiparameter_attributes(pairs)
      )
    end

    def attribute_assignment_error_class
      ActiveModel::AttributeAssignmentError
    end

    def multiparameter_assignment_errors_class
      ActiveModel::MultiparameterAssignmentErrors
    end

    def unknown_attribute_error_class
      ActiveModel::UnknownAttributeError
    end

    def execute_callstack_for_multiparameter_attributes(callstack)
      errors = []
      callstack.each do |name, values_with_empty_parameters|
        begin
          unless respond_to?("#{name}=")
            raise unknown_attribute_error_class, "unknown attribute: #{name}"
          end

          attr_class = self.class.const_get('MultiparameterAttribute')
          send("#{name}=", attr_class.new(self, name, values_with_empty_parameters).read_value)
        rescue => ex
          errors << attribute_assignment_error_class.new("error on assignment #{values_with_empty_parameters.values.inspect} to #{name} (#{ex.message})", ex, name)
        end
      end
      unless errors.empty?
        error_descriptions = errors.map { |ex| ex.message }.join(",")
        raise multiparameter_assignment_errors_class.new(errors), "#{errors.size} error(s) on assignment of multiparameter attributes [#{error_descriptions}]"
      end
    end

    def extract_callstack_for_multiparameter_attributes(pairs)
      attributes = {}

      pairs.each do |(multiparameter_name, value)|
        attribute_name = multiparameter_name.split("(").first
        attributes[attribute_name] ||= {}

        parameter_value = value.empty? ? nil : type_cast_attribute_value(multiparameter_name, value)
        attributes[attribute_name][find_parameter_position(multiparameter_name)] ||= parameter_value
      end

      attributes
    end

    def type_cast_attribute_value(multiparameter_name, value)
      multiparameter_name =~ /\([0-9]*([if])\)/ ? value.send("to_" + $1) : value
    end

    def find_parameter_position(multiparameter_name)
      multiparameter_name.scan(/\(([0-9]*).*\)/).first.first.to_i
    end

    class MultiparameterAttribute #:nodoc:
      attr_reader :object, :name, :values

      def initialize(object, name, values)
        @object = object
        @name   = name
        @values = values
      end

      def class_for_attribute
        object.class_for_attribute(name)
      end

      def read_value
        return if values.values.compact.empty?

        klass = class_for_attribute

        if klass.nil?
          raise UnexpectedMultiparameterValueError,
                "Did not expect a multiparameter value for #{name}. " +
                "You may be passing the wrong value, or you need to modify " +
                "class_for_attribute so that it returns the right class for " +
                "#{name}."
        elsif klass == Time
          read_time
        elsif klass == Date
          read_date
        else
          read_other(klass)
        end
      end

      private

      def instantiate_time_object(set_values)
        Time.zone.local(*set_values)
      end

      def read_time
        validate_required_parameters!([1,2,3])
        return if blank_date_parameter?

        max_position = extract_max_param(6)
        set_values   = values.values_at(*(1..max_position))
        # If Time bits are not there, then default to 0
        (3..5).each { |i| set_values[i] = set_values[i].presence || 0 }
        instantiate_time_object(set_values)
      end

      def read_date
        return if blank_date_parameter?
        set_values = values.values_at(1,2,3)
        begin
          Date.new(*set_values)
        rescue ArgumentError # if Date.new raises an exception on an invalid date
          instantiate_time_object(set_values).to_date # we instantiate Time object and convert it back to a date thus using Time's logic in handling invalid dates
        end
      end

      def read_other(klass)
        max_position = extract_max_param
        positions    = (1..max_position)
        validate_required_parameters!(positions)

        set_values = values.values_at(*positions)
        klass.new(*set_values)
      end

      # Checks whether some blank date parameter exists. Note that this is different
      # than the validate_required_parameters! method, since it just checks for blank
      # positions instead of missing ones, and does not raise in case one blank position
      # exists. The caller is responsible to handle the case of this returning true.
      def blank_date_parameter?
        (1..3).any? { |position| values[position].blank? }
      end

      # If some position is not provided, it errors out a missing parameter exception.
      def validate_required_parameters!(positions)
        if missing_parameter = positions.detect { |position| !values.key?(position) }
          raise ArgumentError.new("Missing Parameter - #{name}(#{missing_parameter})")
        end
      end

      def extract_max_param(upper_cap = 100)
        [values.keys.max, upper_cap].min
      end
    end
  end
end
