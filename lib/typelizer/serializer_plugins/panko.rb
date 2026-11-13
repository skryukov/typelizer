require_relative "base"

module Typelizer
  module SerializerPlugins
    class Panko < Base
      def properties
        if public_descriptor?
          properties_from_public_descriptor
        else
          properties_from_internal_descriptor
        end
      end

      private

      # Panko >= 1.0 exposes a public, read-only Panko::Descriptor
      def public_descriptor?
        defined?(::Panko::Descriptor) && ::Panko::Descriptor.respond_to?(:for)
      end

      def properties_from_public_descriptor
        descriptor = ::Panko::Descriptor.for(serializer)

        attributes = (descriptor.attributes + descriptor.method_attributes).map do |att|
          build_attribute_property(name: att.name.to_s, column_name: (att.source || att.name).to_s)
        end

        # has_many before has_one, matching the property order of Panko < 1.0
        has_many, has_one = descriptor.associations.partition { |assoc| assoc.kind == :has_many }
        associations = (has_many + has_one).map do |assoc|
          build_association_property(
            name: assoc.name.to_s,
            serializer: assoc.descriptor.serializer,
            multi: assoc.kind == :has_many
          )
        end

        attributes + associations
      end

      # Panko < 1.0 keeps its descriptor in an instance variable of the C extension
      def properties_from_internal_descriptor
        descriptor = serializer.new.instance_variable_get(:@descriptor)

        attributes = (descriptor.attributes + descriptor.method_fields).map do |att|
          build_attribute_property(name: att.alias_name || att.name, column_name: att.name)
        end

        has_many = descriptor.has_many_associations.map do |assoc|
          build_association_property(name: assoc.name_str, serializer: assoc.descriptor.type, multi: true)
        end

        has_one = descriptor.has_one_associations.map do |assoc|
          build_association_property(name: assoc.name_str, serializer: assoc.descriptor.type, multi: false)
        end

        attributes + has_many + has_one
      end

      def build_attribute_property(name:, column_name:)
        Property.new(
          name: name,
          optional: false,
          nullable: false,
          multi: false,
          column_name: column_name
        )
      end

      def build_association_property(name:, serializer:, multi:)
        type = serializer ? context.interface_for(serializer) : nil
        Property.new(
          name: name,
          type: type,
          optional: false,
          nullable: false,
          multi: multi,
          column_name: name
        )
      end
    end
  end
end
