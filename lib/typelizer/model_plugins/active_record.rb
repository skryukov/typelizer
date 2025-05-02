module Typelizer
  module ModelPlugins
    class ActiveRecord
      def initialize(model_class:, config:)
        @model_class = model_class
        @config = config
      end

      attr_reader :model_class, :config

      def infer_types(prop)
        if (association = model_class&.reflect_on_association(prop.column_name.to_sym))
          case association.macro
          when :belongs_to
            foreign_key = association.foreign_key
            column = model_class&.columns_hash&.dig(foreign_key.to_s)
            if config.associations_strategy == :database
              prop.nullable = column.null if column
            elsif config.associations_strategy == :active_record
              prop.nullable = !association.options[:required] || association.options[:optional]
            else
              raise "Unknown associations strategy: #{config.associations_strategy}"
            end
          when :has_one
            if config.associations_strategy == :database
              prop.nullable = true
            elsif config.associations_strategy == :active_record
              prop.nullable = !association.options[:required]
            else
              raise "Unknown associations strategy: #{config.associations_strategy}"
            end
          end
          return prop
        end

        column = model_class&.columns_hash&.dig(prop.column_name.to_s)
        return prop unless column

        prop.multi = !!column.try(:array)
        case config.null_strategy
        when :nullable
          prop.nullable = column.null
        when :optional
          prop.optional = column.null
        when :nullable_and_optional
          prop.nullable = column.null
          prop.optional = column.null
        else
          raise "Unknown null strategy: #{config.null_strategy}"
        end

        prop.type = @config.type_mapping[column.type]
        prop.comment = comment_for(prop)
        prop.enum = enum_for(prop)
        prop.type = :string if prop.enum # Ignore underlying column type for enums

        prop
      end

      def comment_for(prop)
        column = model_class&.columns_hash&.dig(prop.column_name.to_s)
        return nil unless column

        prop.comment = column.comment
      end

      def enum_for(prop)
        return unless model_class&.defined_enums&.key?(prop.column_name.to_s)

        prop.enum = model_class.defined_enums[prop.column_name.to_s].keys
      end
    end
  end
end
