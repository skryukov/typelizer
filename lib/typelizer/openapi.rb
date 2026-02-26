# frozen_string_literal: true

module Typelizer
  module OpenAPI
    SUPPORTED_VERSIONS = ["3.0", "3.1"].freeze

    OPENAPI_TYPES = %i[integer number string boolean object array null].freeze
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

    class << self
      def schema_for(interface, openapi_version: "3.0")
        validate_version!(openapi_version)

        required_props = interface.properties.reject(&:optional).map(&:name)
        schema = {
          type: :object,
          properties: interface.properties.to_h { |prop| [prop.name, property_schema(prop, openapi_version: openapi_version)] }
        }
        schema[:required] = required_props if required_props.any?
        schema
      end

      def property_schema(property, openapi_version: "3.0")
        if property.type.is_a?(Array)
          return union_schema(property, openapi_version: openapi_version)
        end

        definition = base_type(property, openapi_version: openapi_version)
        ref = definition.delete("$ref")

        definition = if ref
          ref_schema(ref, property, openapi_version: openapi_version)
        else
          inline_schema(definition, property, openapi_version: openapi_version)
        end

        definition = wrap_traits(definition, property, openapi_version: openapi_version)
        wrap_multi(definition, property, openapi_version: openapi_version)
      end

      private

      def ref_schema(ref, property, openapi_version:)
        ref_obj = {"$ref" => ref}
        item_nullable = !property.multi && property.nullable

        if v31?(openapi_version)
          definition = item_nullable ? {oneOf: [ref_obj, {type: :null}]} : ref_obj
        else
          needs_wrapper = item_nullable || (!property.multi && (property.comment.is_a?(String) || property.deprecated))
          definition = needs_wrapper ? {allOf: [ref_obj]} : ref_obj
          definition[:nullable] = true if item_nullable
        end

        apply_metadata(definition, property) unless property.multi
        definition
      end

      def inline_schema(definition, property, openapi_version:)
        unless property.multi
          apply_nullable(definition, property, openapi_version: openapi_version)
          apply_metadata(definition, property)
        end
        if property.enum.is_a?(Array)
          items_nullable = !property.multi && property.nullable
          definition[:enum] = (items_nullable && !property.enum.include?(nil)) ? property.enum + [nil] : property.enum
        end
        definition
      end

      def union_schema(property, openapi_version:)
        schemas = property.type.map { |part| union_member_schema(part) }

        definition = {anyOf: schemas}

        unless property.multi
          apply_nullable(definition, property, openapi_version: openapi_version)
          apply_metadata(definition, property)
        end

        wrap_multi(definition, property, openapi_version: openapi_version)
      end

      def union_member_schema(type)
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

      def wrap_traits(definition, property, openapi_version:)
        return definition unless property.respond_to?(:with_traits) && property.with_traits&.any? && property.type.respond_to?(:name)

        trait_refs = property.with_traits.map do |t|
          {"$ref" => "#/components/schemas/#{property.type.name}#{t.to_s.camelize}Trait"}
        end

        base_ref = definition.delete("$ref")
        if base_ref
          definition = {allOf: [{"$ref" => base_ref}] + trait_refs}
        elsif definition[:oneOf]
          non_null = definition[:oneOf].reject { |s| s[:type] == :null }
          null_schemas = definition[:oneOf].select { |s| s[:type] == :null }
          all_of = non_null + trait_refs
          definition = null_schemas.any? ? {oneOf: [{allOf: all_of}, *null_schemas]} : {allOf: all_of}
        elsif definition[:allOf]
          definition[:allOf].concat(trait_refs)
        else
          raise ArgumentError, "Unexpected schema shape for traits on property #{property.name}: #{definition.inspect}"
        end

        definition[:nullable] = true if !v31?(openapi_version) && property.nullable
        definition
      end

      def apply_metadata(definition, property)
        definition[:description] = property.comment if property.comment.is_a?(String)
        definition[:deprecated] = true if property.deprecated
      end

      def apply_nullable(definition, property, openapi_version:)
        return unless property.nullable

        if definition[:anyOf]
          v31?(openapi_version) ? definition[:anyOf] << {type: :null} : definition[:nullable] = true
        elsif definition[:type]
          v31?(openapi_version) ? definition[:type] = [definition[:type], :null] : definition[:nullable] = true
        end
      end

      def wrap_multi(definition, property, openapi_version:)
        return definition unless property.multi

        definition = {type: :array, items: definition}
        apply_metadata(definition, property)
        if property.nullable
          v31?(openapi_version) ? definition[:type] = [:array, :null] : definition[:nullable] = true
        end
        definition
      end

      def base_type(property, openapi_version:)
        if property.type.respond_to?(:properties)
          if property.type.respond_to?(:inline?) && property.type.inline?
            schema_for(property.type, openapi_version: openapi_version)
          else
            {"$ref" => "#/components/schemas/#{property.type.name}"}
          end
        elsif property.type.nil? && property.respond_to?(:nested_properties) && property.nested_properties&.any?
          nested_schema(property, openapi_version: openapi_version)
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

      def nested_schema(property, openapi_version:)
        required = property.nested_properties.reject(&:optional).map(&:name)
        schema = {
          type: :object,
          properties: property.nested_properties.to_h { |p| [p.name, property_schema(p, openapi_version: openapi_version)] }
        }
        schema[:required] = required if required.any?
        schema
      end

      def v31?(openapi_version)
        openapi_version.to_s == "3.1"
      end

      def ts_only_type?(type_str)
        type_str.start_with?("{") || type_str.include?("<") || TS_OBJECT_TYPES.include?(type_str)
      end

      def validate_version!(openapi_version)
        raise ArgumentError, "Unsupported openapi_version: #{openapi_version}. Must be one of: #{SUPPORTED_VERSIONS.join(", ")}" unless SUPPORTED_VERSIONS.include?(openapi_version.to_s)
      end
    end
  end
end
