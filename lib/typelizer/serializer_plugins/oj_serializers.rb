require_relative "base"

module Typelizer
  module SerializerPlugins
    class OjSerializers < Base
      def methods_to_typelize
        [
          :has_many, :has_one, :belongs_to,
          :flat_one, :attribute, :attributes
        ]
      end

      def properties
        transform_keys = serializer.try(:_transform_keys)
        attributes = serializer._attributes
        attributes = attributes.transform_keys(&transform_keys) if transform_keys

        attributes
          .flat_map do |key, options|
            if options[:association] == :flat
              Interface.new(serializer: options.fetch(:serializer)).properties
            else
              type = options[:serializer] ? Interface.new(serializer: options[:serializer]) : options[:type]
              Property.new(
                name: key,
                presentation_name: key,
                type: type,
                optional: options[:optional] || options.key?(:if),
                nullable: options[:nullable],
                multi: options[:association] == :many,
                column_name: options.fetch(:value_from)
              )
            end
          end
      end
    end
  end
end
