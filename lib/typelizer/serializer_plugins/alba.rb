require_relative "base"

module Typelizer
  module SerializerPlugins
    class Alba < Base
      ALBA_TS_MAPPER = {
        "String" => {type: :string},
        "Integer" => {type: :number},
        "Boolean" => {type: :boolean},
        "ArrayOfString" => {type: :string, multi: true},
        "ArrayOfInteger" => {type: :number, multi: true}
      }

      def properties
        serializer._attributes.map do |name, attr|
          build_property(name, attr)
        end
      end

      def methods_to_typelize
        [
          :association, :one, :has_one,
          :many, :has_many,
          :attributes, :attribute,
          :nested_attribute, :nested,
          :meta
        ]
      end

      def typelize_method_transform(method:, name:, binding:, type:, attrs:)
        return {name => [type, attrs.merge(multi: true)]} if [:many, :has_many].include?(method)

        super
      end

      def root_key
        serializer.new({}).send(:_key)
      end

      def meta_fields
        return nil unless serializer._meta

        name = serializer._meta.first
        return nil unless name

        [
          build_property(name, name)
        ]
      end

      private

      def build_property(name, attr, **options)
        case attr
        when Symbol
          Property.new(
            name: name,
            type: nil,
            optional: false,
            nullable: false,
            multi: false,
            column_name: name,
            **options
          )
        when Proc
          Property.new(
            name: name,
            type: nil,
            optional: false,
            nullable: false,
            multi: false,
            column_name: nil,
            **options
          )
        when ::Alba::Association
          resource = attr.instance_variable_get(:@resource)
          Property.new(
            name: name,
            type: Interface.new(serializer: resource),
            optional: false,
            nullable: false,
            multi: false, # we override this in typelize_method_transform
            column_name: name,
            **options
          )
        when ::Alba::TypedAttribute
          alba_type = attr.instance_variable_get(:@type)
          Property.new(
            name: name,
            optional: false,
            # not sure if that's a good default tbh
            nullable: !alba_type.instance_variable_get(:@auto_convert),
            multi: false,
            column_name: name,
            **ts_mapper[alba_type.name.to_s],
            **options
          )
        when ::Alba::NestedAttribute
          Property.new(
            name: name,
            type: nil,
            optional: false,
            nullable: false,
            multi: false,
            column_name: nil,
            **options
          )
        when ::Alba::ConditionalAttribute
          build_property(name, attr.instance_variable_get(:@body), optional: true)
        else
          raise ArgumentError, "Unsupported attribute type: #{attr.class}"
        end
      end

      private

      def ts_mapper
        config.plugin_configs.dig(:alba, :ts_mapper) || ALBA_TS_MAPPER
      end
    end
  end
end
