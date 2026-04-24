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
          build_property(name.is_a?(Symbol) ? name.name : name, attr)
        end
      end

      def root_key
        root = serializer.new({}).send(:_key)
        if !root.nil? && has_transform_key?(serializer) && should_transform_root_key?(serializer)
          fetch_key(serializer, root)
        else
          root
        end
      end

      def meta_fields
        return nil unless serializer._meta

        name = serializer._meta.first
        return nil unless name

        [
          build_property(name, name)
        ]
      end

      def traits
        return {} unless serializer.instance_variable_defined?(:@_traits)

        serializer.instance_variable_get(:@_traits) || {}
      end

      def trait_properties(trait_name)
        trait_block = traits[trait_name]
        return [], {} unless trait_block

        collector = BlockAttributeCollector.new
        collector.instance_exec(&trait_block)

        props = collector.collected_attributes.map do |name, attr|
          build_collected_property(name.is_a?(Symbol) ? name.name : name, attr)
        end

        [props, collector.collected_typelizes]
      end

      def build_collected_property(name, attr)
        case attr
        when BlockAttributeCollector::BlockAssociation
          prop_name = has_transform_key?(serializer) ? fetch_key(serializer, name) : name
          with_traits = Array(attr.with_traits) if attr.with_traits
          resource = attr.resource || infer_resource_from_name(name)

          Property.new(
            name: prop_name,
            type: resource ? context.interface_for(resource) : nil,
            optional: false,
            nullable: false,
            multi: attr.multi,
            column_name: name,
            with_traits: with_traits
          )
        when BlockAttributeCollector::BlockNestedAttribute
          prop_name = has_transform_key?(serializer) ? fetch_key(serializer, name) : name
          Property.new(
            name: prop_name,
            type: Shape.new(properties: collect_nested_block(attr.block)),
            optional: false,
            nullable: false,
            multi: false,
            column_name: name
          )
        else
          build_property(name, attr)
        end
      end

      def infer_resource_from_name(name)
        class_name = name.to_s.classify
        # Try common serializer naming conventions
        ["#{class_name}Resource", "#{class_name}Serializer"].each do |resource_name|
          return serializer.const_get(resource_name, false)
        rescue NameError
          # Try in parent namespace
          begin
            return Object.const_get("#{serializer.module_parent}::#{resource_name}")
          rescue NameError
            # Not found in this namespace
          end
        end
        nil
      end

      def trait_interfaces
        @trait_interfaces ||= traits.map do |trait_name, _|
          TraitInterface.new(
            serializer: serializer,
            trait_name: trait_name,
            context: context,
            plugin: self
          )
        end
      end

      private

      def build_property(name, attr, **options)
        column_name = name

        if has_transform_key?(serializer)
          name = fetch_key(serializer, name)
        end

        case attr
        when Symbol
          Property.new(
            name: name,
            type: nil,
            optional: false,
            nullable: false,
            multi: false,
            column_name: column_name,
            **options
          )
        when Proc
          Property.new(
            name: name,
            type: nil,
            optional: false,
            nullable: false,
            multi: false,
            column_name: column_name,
            **options
          )
        when ::Alba::Association
          resource = attr.instance_variable_get(:@resource)
          # Alba stores with_traits directly in @with_traits, not in @params
          with_traits = attr.instance_variable_get(:@with_traits)
          with_traits = Array(with_traits) if with_traits

          Property.new(
            name: name,
            type: context.interface_for(resource),
            optional: false,
            nullable: false,
            multi: false, # we override this in typelize_method_transform
            column_name: attr.name.is_a?(Symbol) ? attr.name.name : attr.name,
            with_traits: with_traits,
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
            column_name: column_name,
            **ts_mapper[alba_type.name.to_s],
            **options
          )
        when ::Alba::NestedAttribute
          block = attr.instance_variable_get(:@block)
          Property.new(
            name: name,
            type: Shape.new(properties: collect_nested_block(block)),
            optional: false,
            nullable: false,
            multi: false,
            column_name: column_name,
            **options
          )
        when ::Alba::ConditionalAttribute
          build_property(column_name, attr.instance_variable_get(:@body), optional: true)
        else
          raise ArgumentError, "Unsupported attribute type: #{attr.class}"
        end
      end

      def has_transform_key?(serializer)
        serializer._transform_type != :none
      end

      def should_transform_root_key?(serializer)
        serializer._transforming_root_key
      end

      def fetch_key(serializer, key)
        ::Alba.transform_key(key, transform_type: serializer._transform_type)
      end

      def ts_mapper
        config.plugin_configs.dig(:alba, :ts_mapper) || ALBA_TS_MAPPER
      end

      def collect_nested_block(block)
        collector = BlockAttributeCollector.new
        collector.instance_exec(&block)
        typelizes = collector.collected_typelizes

        collector.collected_attributes.map do |attr_name, attr|
          attr_name_str = attr_name.is_a?(Symbol) ? attr_name.name : attr_name
          prop = build_collected_property(attr_name_str, attr)
          override = prop.lookup_in(typelizes)
          override&.any? ? prop.with(**override) : prop
        end
      end
    end
  end
end

require_relative "alba/block_attribute_collector"
require_relative "alba/trait_interface"
