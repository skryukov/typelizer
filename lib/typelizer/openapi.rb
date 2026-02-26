# frozen_string_literal: true

module Typelizer
  class OpenAPI
    SUPPORTED_VERSIONS = ["3.0", "3.1"].freeze
    OPENAPI_TYPES = %i[integer number string boolean object array null].freeze
    # TypeScript-only types that have no $ref equivalent in OpenAPI.
    # Strings (not symbols) because ts_only_type? operates on type.to_s values.
    TS_OBJECT_TYPES = %w[any unknown never Record Partial Pick Omit].freeze

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
      validate_version!(openapi_version)

      required_props = interface.properties.reject(&:optional).map(&:name)
      schema = {
        type: :object,
        properties: interface.properties.to_h { |prop| [prop.name, property_schema(prop, openapi_version: openapi_version)] }
      }
      schema[:required] = required_props if required_props.any?
      schema
    end

    def self.property_schema(property, openapi_version: "3.0")
      validate_version!(openapi_version)
      version = Gem::Version.new(openapi_version)

      if property.type.is_a?(Array)
        return union_schema(property, version: version)
      end

      definition = base_type(property)
      ref = definition.delete("$ref")

      definition = if ref
        ref_schema(ref, property, version: version)
      else
        inline_schema(definition, property, version: version)
      end

      wrap_multi(definition, property, version: version)
    end

    def self.ref_schema(ref, property, version:)
      has_siblings = property.nullable || (!property.multi && (property.comment.is_a?(String) || property.deprecated))
      ref_obj = {"$ref" => ref}

      if version >= Gem::Version.new("3.1")
        definition = property.nullable ? {oneOf: [ref_obj, {type: :null}]} : ref_obj
      else
        # In 3.0, $ref must stand alone — use allOf wrapper when siblings are needed
        definition = has_siblings ? {allOf: [ref_obj]} : ref_obj
        definition[:nullable] = true if property.nullable
      end

      # For multi properties, description/deprecated go on the array wrapper (applied in wrap_multi)
      unless property.multi
        definition[:description] = property.comment if property.comment.is_a?(String)
        definition[:deprecated] = true if property.deprecated
      end
      definition
    end

    def self.inline_schema(definition, property, version:)
      # For multi properties, nullable/description/deprecated are applied to the array container in wrap_multi
      unless property.multi
        apply_nullable(definition, property, version: version)
        definition[:description] = property.comment if property.comment.is_a?(String)
        definition[:deprecated] = true if property.deprecated
      end
      if property.enum.is_a?(Array)
        items_nullable = !property.multi && property.nullable
        definition[:enum] = (items_nullable && !property.enum.include?(nil)) ? property.enum + [nil] : property.enum
      end
      definition
    end

    def self.union_schema(property, version:)
      schemas = property.type.map { |part| single_type_schema(part) }

      definition = {anyOf: schemas}

      unless property.multi
        apply_nullable(definition, property, version: version)
        definition[:description] = property.comment if property.comment.is_a?(String)
        definition[:deprecated] = true if property.deprecated
      end

      wrap_multi(definition, property, version: version)
    end

    def self.single_type_schema(type)
      if type.respond_to?(:properties)
        {"$ref" => "#/components/schemas/#{type.name}"}
      else
        sym = type.to_sym
        if OPENAPI_TYPES.include?(sym)
          {type: sym}
        elsif ts_only_type?(type.to_s)
          {type: :object}
        else
          {"$ref" => "#/components/schemas/#{type}"}
        end
      end
    end

    private_class_method :ref_schema, :inline_schema, :union_schema, :single_type_schema

    def self.apply_nullable(definition, property, version:)
      return unless property.nullable

      if definition[:anyOf]
        if version >= Gem::Version.new("3.1")
          definition[:anyOf] << {type: :null}
        else
          definition[:nullable] = true
        end
      elsif definition[:type]
        if version >= Gem::Version.new("3.1")
          definition[:type] = [definition[:type], :null]
        else
          definition[:nullable] = true
        end
      end
    end

    def self.wrap_multi(definition, property, version:)
      return definition unless property.multi

      definition = {type: :array, items: definition}
      definition[:description] = property.comment if property.comment.is_a?(String)
      definition[:deprecated] = true if property.deprecated
      if property.nullable
        if version >= Gem::Version.new("3.1")
          definition[:type] = [:array, :null]
        else
          definition[:nullable] = true
        end
      end
      definition
    end

    def self.base_type(property)
      if property.type.respond_to?(:properties)
        if property.type.respond_to?(:inline?) && property.type.inline?
          schema_for(property.type)
        else
          {"$ref" => "#/components/schemas/#{property.type.name}"}
        end
      elsif property.column_type && COLUMN_TYPE_MAP.key?(property.column_type)
        result = COLUMN_TYPE_MAP[property.column_type].dup
        result[:type] = :string if property.enum
        result
      elsif (property.type.is_a?(String) || property.type.is_a?(Symbol)) && !OPENAPI_TYPES.include?(property.type.to_sym) && !ts_only_type?(property.type.to_s)
        {"$ref" => "#/components/schemas/#{property.type}"}
      else
        type = property.type.to_s.to_sym
        OPENAPI_TYPES.include?(type) ? {type: type} : {type: :object}
      end
    end

    def self.ts_only_type?(type_str)
      type_str.include?("<") || TS_OBJECT_TYPES.include?(type_str.split("<", 2).first)
    end

    def self.validate_version!(openapi_version)
      raise ArgumentError, "Unsupported openapi_version: #{openapi_version}. Must be one of: #{SUPPORTED_VERSIONS.join(", ")}" unless SUPPORTED_VERSIONS.include?(openapi_version.to_s)
    end

    private_class_method :base_type, :ts_only_type?, :apply_nullable, :wrap_multi, :validate_version!
  end
end
