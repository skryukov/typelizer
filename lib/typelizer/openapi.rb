# frozen_string_literal: true

module Typelizer
  class OpenAPI
    SUPPORTED_VERSIONS = ["3.0", "3.1"].freeze
    OPENAPI_TYPES = %i[integer number string boolean object array null].freeze

    COLUMN_TYPE_MAP = {
      integer: {type: :integer},
      bigint: {type: :integer, format: :int64},
      decimal: {type: :number, format: :double},
      float: {type: :number, format: :float},
      boolean: {type: :boolean},
      string: {type: :string},
      text: {type: :string},
      citext: {type: :string},
      uuid: {type: :string, format: :uuid},
      date: {type: :string, format: :date},
      datetime: {type: :string, format: :"date-time"},
      time: {type: :string, format: :time},
      json: {type: :object},
      jsonb: {type: :object},
      binary: {type: :string, format: :binary},
      inet: {type: :string},
      cidr: {type: :string}
    }.freeze

    def self.schema_for(interface, openapi_version: "3.0")
      raise ArgumentError, "Unsupported openapi_version: #{openapi_version}. Must be one of: #{SUPPORTED_VERSIONS.join(", ")}" unless SUPPORTED_VERSIONS.include?(openapi_version.to_s)

      required_props = interface.properties.reject(&:optional).map(&:name)
      schema = {
        type: :object,
        properties: interface.properties.to_h { |prop| [prop.name, property_schema(prop, openapi_version: openapi_version)] }
      }
      schema[:required] = required_props if required_props.any?
      schema
    end

    def self.property_schema(property, openapi_version: "3.0")
      raise ArgumentError, "Unsupported openapi_version: #{openapi_version}. Must be one of: #{SUPPORTED_VERSIONS.join(", ")}" unless SUPPORTED_VERSIONS.include?(openapi_version.to_s)

      definition = base_type(property)
      ref = definition.delete("$ref")

      definition = if ref
        ref_schema(ref, property, openapi_version: openapi_version)
      else
        inline_schema(definition, property, openapi_version: openapi_version)
      end

      if property.multi
        definition = {type: :array, items: definition}
        if property.nullable
          if openapi_version.to_s >= "3.1"
            definition[:type] = [:array, :null]
          else
            definition[:nullable] = true
          end
        end
      end

      definition
    end

    def self.ref_schema(ref, property, openapi_version:)
      has_siblings = property.nullable || property.comment.is_a?(String) || property.deprecated
      ref_obj = {"$ref" => ref}

      if openapi_version.to_s >= "3.1"
        definition = property.nullable ? {oneOf: [ref_obj, {type: :null}]} : ref_obj
      else
        # In 3.0, $ref must stand alone — use allOf wrapper when siblings are needed
        definition = has_siblings ? {allOf: [ref_obj]} : ref_obj
        definition[:nullable] = true if property.nullable
      end

      definition[:description] = property.comment if property.comment.is_a?(String)
      definition[:deprecated] = true if property.deprecated
      definition
    end

    def self.inline_schema(definition, property, openapi_version:)
      # For multi properties, nullable is applied to the array container in property_schema
      unless property.multi
        if property.nullable
          if openapi_version.to_s >= "3.1"
            definition[:type] = [definition[:type], :null]
          else
            definition[:nullable] = true
          end
        end
      end
      definition[:description] = property.comment if property.comment.is_a?(String)
      if property.enum.is_a?(Array)
        items_nullable = !property.multi && property.nullable
        definition[:enum] = (items_nullable && !property.enum.include?(nil)) ? property.enum + [nil] : property.enum
      end
      definition[:deprecated] = true if property.deprecated
      definition
    end
    private_class_method :ref_schema, :inline_schema

    def self.base_type(property)
      if property.type.respond_to?(:properties)
        {"$ref" => "#/components/schemas/#{property.type.name}"}
      elsif property.column_type && COLUMN_TYPE_MAP.key?(property.column_type)
        result = COLUMN_TYPE_MAP[property.column_type].dup
        result[:type] = :string if property.enum
        result
      elsif property.type.is_a?(String) && !OPENAPI_TYPES.include?(property.type.to_sym)
        {"$ref" => "#/components/schemas/#{property.type}"}
      else
        type = property.type.to_s.to_sym
        if OPENAPI_TYPES.include?(type)
          {type: type}
        else
          {type: :object}
        end
      end
    end
    private_class_method :base_type
  end
end
