module Typelizer
  module ModelPlugins
    class ActiveRecord
      def initialize(model_class:, config:)
        @model_class = model_class
        @config = config
      end

      attr_reader :model_class, :config

      def infer_types(prop)
        infer_types_for_association(prop) ||
          infer_types_for_column(prop) ||
          infer_types_for_association_ids(prop) ||
          infer_types_for_attribute(prop)

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
        prop.enum_type_name = "#{model_class.name.demodulize}#{prop.column_name.to_s.camelize}"
        prop.enum
      end

      private

      def infer_types_for_association(prop)
        association = model_class&.reflect_on_association(prop.column_name.to_sym)
        return nil unless association

        case association.macro
        when :belongs_to
          foreign_key = association.foreign_key
          column = model_class&.columns_hash&.dig(foreign_key.to_s)
          if config.associations_strategy == :database
            prop.nullable = column.null if column
          elsif config.associations_strategy == :active_record
            prop.nullable = association.options[:optional] === true || association.options[:required] === false
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

        prop
      end

      def infer_types_for_column(prop)
        column = model_class&.columns_hash&.dig(prop.column_name.to_s)
        return nil unless column

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

      def infer_types_for_association_ids(prop)
        column_name = prop.column_name.to_s
        return nil unless column_name.end_with?("_ids")

        base_name = column_name.chomp("_ids").pluralize
        association = model_class&.reflect_on_association(base_name.to_sym)
        return nil unless association

        prop.type = :number
        prop.multi = true
        prop
      end

      def infer_types_for_attribute(prop)
        return nil unless model_class.respond_to?(:attribute_types)

        attribute_type_obj = model_class.attribute_types.fetch(prop.column_name.to_s, nil)
        return nil unless attribute_type_obj

        if attribute_type_obj.instance_of?(::ActiveRecord::Type::Serialized)
          return infer_types_for_serialized(prop, attribute_type_obj)
        end

        if attribute_type_obj.respond_to?(:subtype)
          prop.type = @config.type_mapping[attribute_type_obj.subtype.type]
          prop.multi = true
        elsif attribute_type_obj.respond_to?(:type)
          prop.type = @config.type_mapping[attribute_type_obj.type]
        end

        prop
      end

      def infer_types_for_serialized(prop, type_obj)
        object_class = type_obj.coder.try(:object_class) ||
          type_obj.try(:object_class)

        case object_class&.to_s
        when "Array"
          prop.type = :unknown
          prop.multi = true
        when "Hash"
          prop.type = "Record<string, unknown>"
        else
          prop.type = :unknown
        end

        prop
      end
    end
  end
end
