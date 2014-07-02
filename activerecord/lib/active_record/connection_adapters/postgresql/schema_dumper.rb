module ActiveRecord
  module ConnectionAdapters
    module PostgreSQL
      module SchemaDumper # :nodoc:
        def print_primary_key_type(column, printer)
          case column.type
          when :uuid
            printer.print(", id: :uuid")
            if column.default_function
              printer.print(%Q(, default: "#{column.default_function}"))
            end
          when :big_integer
            printer.print(", id: :bigserial")
          else
            super
          end
        end
      end
    end
  end
end
