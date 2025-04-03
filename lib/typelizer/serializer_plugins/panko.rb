require_relative "base"

module Typelizer
  module SerializerPlugins
    class Panko < Base
      def methods_to_typelize
        [:has_many, :has_one, :attributes]
      end

      def properties
        attributes = serializer.new.instance_variable_get(:@descriptor).attributes
        methods_attributes = serializer.new.instance_variable_get(:@descriptor).method_fields
        has_many_associations = serializer.new.instance_variable_get(:@descriptor).has_many_associations
        has_one_associations = serializer.new.instance_variable_get(:@descriptor).has_one_associations

        attributes.map do |att|
          attribute_property(att)
        end + methods_attributes.map do |att|
          attribute_property(att)
        end + has_many_associations.map do |assoc|
          association_property(assoc, multi: true)
        end + has_one_associations.map do |assoc|
          association_property(assoc, multi: false)
        end
      end

      private

      def attribute_property(att)
        Property.new(
          name: att.alias_name || att.name,
          type: infer_type_from_model(att.name), # options[:type] ||
          optional: false,
          nullable: false,
          multi: false,
          column_name: att.name
        )
      end

      def association_property(assoc, multi = false)
        key = assoc.name_str
        serializer = assoc.descriptor.type
        type = serializer ? Interface.new(serializer: serializer) : infer_type_from_association(key)
        Property.new(
          name: key,
          type: type,
          optional: false,
          nullable: false,
          multi: multi,
          column_name: key
        )
      end

      def infer_type_from_model(attribute)
        model_class = serializer.instance_variable_get(:@model_class)
        return "unknown" unless model_class

        column = model_class.columns_hash[attribute.to_s]
        column ? column.type : "unknown"
      end

      def infer_type_from_association(attribute)
        assoc = serializer.instance_variable_get(:@model_class).reflect_on_association(attribute)
        assoc ? assoc.klass.name : "unknown"
      end
    end
  end
end
