require_relative "base"

module Typelizer
  module SerializerPlugins
    class Panko < Base
      def methods_to_typelize
        [:has_many, :has_one, :attributes]
      end

      def properties
        descriptor = serializer.new.instance_variable_get(:@descriptor)
        attributes = descriptor.attributes
        methods_attributes = descriptor.method_fields
        has_many_associations = descriptor.has_many_associations
        has_one_associations = descriptor.has_one_associations

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
          optional: false,
          nullable: false,
          multi: false,
          column_name: att.name
        )
      end

      def association_property(assoc, multi: false)
        key = assoc.name_str
        serializer = assoc.descriptor.type
        type = serializer ? Interface.new(serializer: serializer) : nil
        Property.new(
          name: key,
          type: type,
          optional: false,
          nullable: false,
          multi: multi,
          column_name: key
        )
      end
    end
  end
end
