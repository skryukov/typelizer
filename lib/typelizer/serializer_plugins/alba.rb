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

      def methods_to_typelize
        [
          :association, :one, :has_one,
          :many, :has_many,
          :attributes, :attribute,
          :method_added,
          :nested_attribute, :nested,
          :meta
        ]
      end

      def typelize_method_transform(method:, name:, binding:, type:, attrs:)
        if method == :method_added && binding.local_variable_defined?(:method_name)
          name = binding.local_variable_get(:method_name)
        end

        if [:many, :has_many].include?(method)
          return {name => [type, attrs.merge(multi: true)]}
        end

        super
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
          params = attr.instance_variable_get(:@params)

          # Check if association has select params
          if params && params[:select]
            selected_fields = params[:select]
            type = create_select_type(resource, selected_fields, name)
          else
            type = context.interface_for(resource)
          end

          Property.new(
            name: name,
            type: type,
            optional: false,
            nullable: false,
            multi: false, # we override this in typelize_method_transform
            column_name: attr.name.is_a?(Symbol) ? attr.name.name : attr.name,
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
          Property.new(
            name: name,
            type: nil,
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

      private

      def ts_mapper
        config.plugin_configs.dig(:alba, :ts_mapper) || ALBA_TS_MAPPER
      end

      # Creates a specialized type for associations with select params
      def create_select_type(resource, selected_fields, association_name)
        # Get the base interface for the resource
        base_interface = context.interface_for(resource)

        # Create a unique type name based on parent serializer and association
        parent_name = serializer.name || "Unknown"
        association_part = association_name.to_s.capitalize
        select_type_name = "#{parent_name}#{association_part}Select"

        # Get or create the select type interface
        context.find_or_create_select_interface(
          name: select_type_name,
          base_interface: base_interface,
          selected_fields: selected_fields
        )
      rescue => e
        # Fallback to full interface if something goes wrong
        Typelizer.logger.debug("Failed to create select type: #{e.message}")
        context.interface_for(resource)
      end
    end
  end
end
