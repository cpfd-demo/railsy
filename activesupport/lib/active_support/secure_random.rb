begin
  require 'securerandom'
rescue LoadError
end

module ActiveSupport
  if defined?(::SecureRandom)
    # Use Ruby's SecureRandom library if available.
    SecureRandom = ::SecureRandom # :nodoc:
  else
    # = Secure random number generator interface.
    #
    # This library is an interface for secure random number generator which is
    # suitable for generating session key in HTTP cookies, etc.
    #
    # It supports following secure random number generators.
    #
    # * openssl
    # * /dev/urandom
    # * Win32
    #
    # *Note*: This module is based on the SecureRandom library from Ruby 1.9,
    # revision 18786, August 23 2008. It's 100% interface-compatible with Ruby 1.9's
    # SecureRandom library, with the exception of the two added methods:
    # random_from_set and random_unambiguous_code, which Ruby lacks
    #
    # == Example
    #
    #  # random hexadecimal string.
    #  p SecureRandom.hex(10) # => "52750b30ffbc7de3b362"
    #  p SecureRandom.hex(10) # => "92b15d6c8dc4beb5f559"
    #  p SecureRandom.hex(11) # => "6aca1b5c58e4863e6b81b8"
    #  p SecureRandom.hex(12) # => "94b2fff3e7fd9b9c391a2306"
    #  p SecureRandom.hex(13) # => "39b290146bea6ce975c37cfc23"
    #  ...
    #
    #  # random base64 string.
    #  p SecureRandom.base64(10) # => "EcmTPZwWRAozdA=="
    #  p SecureRandom.base64(10) # => "9b0nsevdwNuM/w=="
    #  p SecureRandom.base64(10) # => "KO1nIU+p9DKxGg=="
    #  p SecureRandom.base64(11) # => "l7XEiFja+8EKEtY="
    #  p SecureRandom.base64(12) # => "7kJSM/MzBJI+75j8"
    #  p SecureRandom.base64(13) # => "vKLJ0tXBHqQOuIcSIg=="
    #  ...
    #
    #  # random binary string.
    #  p SecureRandom.random_bytes(10) # => "\016\t{\370g\310pbr\301"
    #  p SecureRandom.random_bytes(10) # => "\323U\030TO\234\357\020\a\337"
    #  ...
    #
    #  # random choices from set
    #  p SecureRandom.random_from_set(3,['a','b','z',4,2]) # => ['z',4,'b']
    #  p SecureRandom.random_form_set(8,[3,6,1,7,3])       # => [ 3,6,1,3,7,3,6,3 ]
    #  ...
    #
    #  # random unambigous code
    #  p SecureRandom.random_unambiguous_code(8) # => "KRA2GZYA"
    #  p SecureRandom.random_unambiguous_code(4) # => "EV3Z"
    #  ...
 
    module SecureRandom

      # Generates a random binary string.
      #
      # The argument n specifies the length of the result string.
      #
      # If n is not specified, 16 is assumed.
      # It may be larger in future.
      #
      # If secure random number generator is not available,
      # NotImplementedError is raised.
      #
      def self.random_bytes(n=nil)
        n ||= 16

        unless defined? OpenSSL
          begin
            require 'openssl'
          rescue LoadError
          end
        end

        if defined? OpenSSL::Random
          return OpenSSL::Random.random_bytes(n)
        end

        if !defined?(@has_urandom) || @has_urandom
          flags = File::RDONLY
          flags |= File::NONBLOCK if defined? File::NONBLOCK
          flags |= File::NOCTTY if defined? File::NOCTTY
          flags |= File::NOFOLLOW if defined? File::NOFOLLOW
          begin
            File.open("/dev/urandom", flags) {|f|
              unless f.stat.chardev?
                raise Errno::ENOENT
              end
              @has_urandom = true
              ret = f.readpartial(n)
              if ret.length != n
                raise NotImplementedError, "Unexpected partial read from random device"
              end
              return ret
            }
          rescue Errno::ENOENT
            @has_urandom = false
          end
        end

        unless defined?(@has_win32)
          begin
            require 'Win32API'

            crypt_acquire_context = Win32API.new("advapi32", "CryptAcquireContext", 'PPPII', 'L')
            @crypt_gen_random = Win32API.new("advapi32", "CryptGenRandom", 'LIP', 'L')

            hProvStr = " " * 4
            prov_rsa_full = 1
            crypt_verifycontext = 0xF0000000

            if crypt_acquire_context.call(hProvStr, nil, nil, prov_rsa_full, crypt_verifycontext) == 0
              raise SystemCallError, "CryptAcquireContext failed: #{lastWin32ErrorMessage}"
            end
            @hProv, = hProvStr.unpack('L')

            @has_win32 = true
          rescue LoadError
            @has_win32 = false
          end
        end
        if @has_win32
          bytes = " " * n
          if @crypt_gen_random.call(@hProv, bytes.size, bytes) == 0
            raise SystemCallError, "CryptGenRandom failed: #{lastWin32ErrorMessage}"
          end
          return bytes
        end

        raise NotImplementedError, "No random device"
      end

      # Generates a random hex string.
      #
      # The argument n specifies the length of the random length.
      # The length of the result string is twice of n.
      #
      # If n is not specified, 16 is assumed.
      # It may be larger in future.
      #
      # If secure random number generator is not available,
      # NotImplementedError is raised.
      #
      def self.hex(n=nil)
        random_bytes(n).unpack("H*")[0]
      end

      # Generates a random base64 string.
      #
      # The argument n specifies the length of the random length.
      # The length of the result string is about 4/3 of n.
      #
      # If n is not specified, 16 is assumed.
      # It may be larger in future.
      #
      # If secure random number generator is not available,
      # NotImplementedError is raised.
      #
      def self.base64(n=nil)
        [random_bytes(n)].pack("m*").delete("\n")
      end

      # Generates a random number.
      #
      # If an positive integer is given as n,
      # SecureRandom.random_number returns an integer:
      # 0 <= SecureRandom.random_number(n) < n.
      #
      # If 0 is given or an argument is not given,
      # SecureRandom.random_number returns an float:
      # 0.0 <= SecureRandom.random_number() < 1.0.
      #
      def self.random_number(n=0)
        if 0 < n
          hex = n.to_s(16)
          hex = '0' + hex if (hex.length & 1) == 1
          bin = [hex].pack("H*")
          mask = bin[0]
          mask |= mask >> 1
          mask |= mask >> 2
          mask |= mask >> 4
          begin
            rnd = SecureRandom.random_bytes(bin.length)
            rnd[0] = rnd[0] & mask
          end until rnd < bin
          rnd.unpack("H*")[0].hex
        else
          # assumption: Float::MANT_DIG <= 64
          i64 = SecureRandom.random_bytes(8).unpack("Q")[0]
          Math.ldexp(i64 >> (64-Float::MANT_DIG), -Float::MANT_DIG)
        end
      end

      # Following code is based on David Garamond's GUID library for Ruby.
      def self.lastWin32ErrorMessage # :nodoc:
        get_last_error = Win32API.new("kernel32", "GetLastError", '', 'L')
        format_message = Win32API.new("kernel32", "FormatMessageA", 'LPLLPLPPPPPPPP', 'L')
        format_message_ignore_inserts = 0x00000200
        format_message_from_system    = 0x00001000

        code = get_last_error.call
        msg = "\0" * 1024
        len = format_message.call(format_message_ignore_inserts + format_message_from_system, 0, code, 0, msg, 1024, nil, nil, nil, nil, nil, nil, nil, nil)
        msg[0, len].tr("\r", '').chomp
      end
    end
  end
  module SecureRandom
    # Choose n random values from set.
    #
    # The argument n specifies the length of the returned array
    #
    # Set must be of a type that supports the 
    # index access and the appends operators [] and << 
    # such as a String or Array
    #
    # Returns an object of the same type as set
    #
    # If secure random number generator is not available,
    # NotImplementedError is raised.
    def self.random_from_set( n, set )
      ret = set.class.new
      SecureRandom.random_bytes( n ).each_byte do |b|
        ret << set[  b >= set.length ? b % set.length : b ]
      end
      ret
    end
    # Return a code of n length 
    # without using letters & numbers that could
    # be easily confused with one another
    #
    # The argument n specifies the length of the returned string
    #
    # The chars argument defaults to the an ASCII alphabet subset;
    # with lowercase characters, 
    # the numbers 0, 1, 8 and the letters B, I, O, S, U
    # eliminated
    #
    # Ideal for generating unique access codes
    # or temporary passwords which might have
    # to be written down or passed on verbally
    #
    # If secure random number generator is not available,
    # NotImplementedError is raised.
    def self.random_unambiguous_code( n, chars='234679ACDEFGHJKLMNPQRTVWXYZ')
      self.random_from_set(n,chars)
    end
  end
end
