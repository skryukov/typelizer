require_relative "base"

module Typelizer
  module SerializerPlugins
    class AMS < Base
      def methods_to_typelize
        [
          :has_many, :has_one, :belongs_to,
          :attribute, :attributes
        ]
      end

      def typelize_method_transform(method:, name:, binding:, type:, attrs:)
        return {binding.local_variable_get(:attr) => [type, attrs]} if method == :attribute

        super
      end

      def properties
        serializer._attributes_data.merge(serializer._reflections).flat_map do |key, association|
          type = association.options[:serializer] ? Interface.new(serializer: association.options[:serializer]) : nil
          Property.new(
            name: key.to_s,
            type: type,
            optional: association.options.key?(:if) || association.options.key?(:unless),
            multi: association.respond_to?(:collection?) && association.collection?,
            column_name: association.name.to_s
          )
        end
      end
    end
  end
end
