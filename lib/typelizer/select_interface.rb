# frozen_string_literal: true

module Typelizer
  # SelectInterface represents a specialized interface that only includes
  # selected fields from a base interface. Used for Alba associations with
  # params: {select: [...]}
  class SelectInterface
    attr_reader :name, :base_interface, :selected_fields, :context

    def initialize(name:, base_interface:, selected_fields:, context:)
      @name = name
      @base_interface = base_interface
      @selected_fields = Array(selected_fields).map(&:to_s)
      @context = context
    end

    def config
      base_interface.config
    end

    def inline?
      false # Select interfaces are always named types
    end

    def filename
      name.gsub("::", "/")
    end

    def root_key
      nil # Select types don't have root keys
    end

    def empty?
      properties.empty?
    end

    def meta_fields
      [] # Select types don't have meta fields
    end

    def properties
      @properties ||= filter_properties
    end

    def parent_interface
      nil # Select types don't have inheritance
    end

    def properties_to_print
      properties
    end

    def imports
      @imports ||= begin
        association_serializers, attribute_types = properties.filter_map(&:type)
          .uniq
          .partition { |type| type.is_a?(Interface) || type.is_a?(SelectInterface) }

        serializer_types = association_serializers
          .filter_map { |interface| interface.name if interface.name != name && !interface.inline? }

        custom_type_imports = attribute_types
          .flat_map { |type| extract_typescript_types(type.to_s) }
          .uniq
          .reject { |type| global_type?(type) }

        (custom_type_imports + serializer_types).uniq
      end
    end

    def quote(str)
      config.prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    def inspect
      "<#{self.class.name} #{name} selected=#{selected_fields.inspect}>"
    end

    def fingerprint
      "<#{self.class.name} #{name} selected=#{selected_fields.inspect}>"
    end

    private

    def filter_properties
      # Get all properties from the base interface
      all_props = base_interface.properties

      # Filter to only include selected fields
      # Also check for transformed field names in case of transform_keys
      all_props.select do |prop|
        field_name = prop.name.to_s
        column_name = prop.column_name.to_s

        selected_fields.include?(field_name) ||
          selected_fields.include?(column_name) ||
          # Also check camelCase/snake_case variations
          selected_fields.include?(to_camel_case(field_name)) ||
          selected_fields.include?(to_snake_case(field_name)) ||
          selected_fields.include?(to_camel_case(column_name)) ||
          selected_fields.include?(to_snake_case(column_name))
      end
    end

    def to_camel_case(str)
      str.to_s.gsub(/_([a-z])/) { $1.upcase }
    end

    def to_snake_case(str)
      str.to_s.gsub(/([A-Z])/) { "_#{$1.downcase}" }.sub(/^_/, "")
    end

    def extract_typescript_types(type)
      type.split(/[<>\[\],\s|]+/)
    end

    def global_type?(type)
      type[0] == type[0].downcase || config.types_global.include?(type)
    end
  end
end
