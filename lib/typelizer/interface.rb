require_relative "type_inference"

module Typelizer
  class Interface
    include TypeInference

    attr_reader :serializer, :context

    def initialize(serializer:, context:)
      @serializer = serializer
      @context = context
    end

    def config
      context.config_for(serializer)
    end

    def serializer_plugin
      @serializer_plugin ||= config.serializer_plugin.new(
        serializer: serializer,
        config: config,
        context: context
      )
    end

    def inline?
      !serializer.is_a?(Class) || serializer.name.nil?
    end

    def name
      if inline?
        Renderer.call("inline_type.ts.erb", properties: properties, sort_order: config.properties_sort_order).strip
      else
        config.serializer_name_mapper.call(serializer).tr_s(":", "")
      end
    end

    def filename
      name.gsub("::", "/")
    end

    def root_key
      serializer_plugin.root_key
    end

    def empty?
      meta_fields.empty? && properties.empty?
    end

    def meta_fields
      @meta_fields ||= begin
        props = serializer_plugin.meta_fields || []
        props = infer_types(props, :_typelizer_meta_attributes)
        props = config.properties_transformer.call(props) if config.properties_transformer
        PropertySorter.sort(props, config.properties_sort_order)
      end
    end

    def trait_interfaces
      return [] unless serializer_plugin.respond_to?(:trait_interfaces)

      @trait_interfaces ||= serializer_plugin.trait_interfaces
    end

    def enum_types
      @enum_types ||= begin
        all_properties = collect_all_properties(properties + trait_interfaces.flat_map(&:properties))
        all_properties
          .select(&:enum_definition)
          .uniq(&:enum_type_name)
      end
    end

    def properties
      @properties ||= begin
        props = serializer_plugin.properties
        props = infer_types(props)
        props = config.properties_transformer.call(props) if config.properties_transformer
        PropertySorter.sort(props, config.properties_sort_order)
      end
    end

    def overwritten_properties
      return [] unless parent_interface

      @overwritten_properties ||= parent_interface.properties - properties
    end

    def own_properties
      @own_properties ||= properties - (parent_interface&.properties || [])
    end

    def properties_to_print
      parent_interface ? own_properties : properties
    end

    def parent_interface
      return if config.inheritance_strategy == :none

      parent_class = serializer.superclass
      return unless parent_class.respond_to?(:typelizer_config)

      parent_interface = context.interface_for(parent_class)
      return if parent_interface.empty?

      parent_interface
    end

    def imports
      @imports ||= begin
        # Include both main properties and trait properties for import collection,
        # recursively including nested sub-properties
        all_properties = collect_all_properties(properties_to_print + trait_interfaces.flat_map(&:properties))

        flat_types = all_properties.filter_map(&:type).flat_map { |t| Array(t) }.uniq
        association_serializers, attribute_types = flat_types.partition { |type| type.is_a?(Interface) }

        serializer_types = association_serializers
          .filter_map { |interface| interface.name if interface.name != name && !interface.inline? }

        custom_type_imports = attribute_types
          .flat_map { |type| extract_typescript_types(type.to_s) }
          .uniq
          .reject { |type| global_type?(type) }

        # Collect trait types from properties with with_traits (skip self-references)
        trait_imports = all_properties.flat_map do |prop|
          next [] unless prop.with_traits&.any? && prop.type.is_a?(Interface)
          # Skip if the trait types are from the current interface (same file)
          next [] if prop.type.name == name

          prop.with_traits.map { |t| "#{prop.type.name}#{t.to_s.camelize}Trait" }
        end

        # Collect enum type names from properties
        enum_imports = all_properties.filter_map(&:enum_type_name)

        result = (custom_type_imports + serializer_types + trait_imports + enum_imports + Array(parent_interface&.name)).uniq - [self_type_name, name]
        ImportSorter.sort(result, config.imports_sort_order)
      end
    end

    def inspect
      "<#{self.class.name} #{name} properties=#{properties.inspect}>"
    end

    def fingerprint
      [
        name,
        properties_to_print.map(&:fingerprint),
        parent_interface&.name,
        root_key,
        meta_fields.map(&:fingerprint),
        trait_interfaces.map { |t| [t.name, t.properties.map(&:fingerprint)] },
        CONFIGS_AFFECTING_OUTPUT.map { |key| config.public_send(key) }
      ].inspect
    end

    def quote(str)
      config.prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    private

    def collect_all_properties(props)
      props.flat_map do |prop|
        if prop.nested_properties&.any?
          [prop] + collect_all_properties(prop.nested_properties)
        elsif prop.type.is_a?(Interface) && prop.type.inline?
          [prop] + collect_all_properties(prop.type.properties)
        else
          [prop]
        end
      end
    end

    def self_type_name
      serializer.name.match(/(\w+::)?(\w+)(Serializer|Resource)/)[2]
    end

    def extract_typescript_types(type)
      type.split(/[<>\[\],\s|]+/).reject(&:empty?)
    end

    def global_type?(type)
      type[0] == type[0].downcase || config.types_global.include?(type)
    end

    def infer_types(props, hash_name = :_typelizer_attributes)
      dsl_attrs = serializer.respond_to?(hash_name) ? serializer.public_send(hash_name) : {}
      multi_attrs = serializer.respond_to?(:_typelizer_multi_attributes) ? serializer._typelizer_multi_attributes : Set.new

      props.map do |prop|
        has_dsl = dsl_attrs_for(prop, dsl_attrs)&.any?

        prop
          .then { |p| apply_dsl_type(p, dsl_attrs) }
          .then { |p| has_dsl ? p : apply_model_inference(p) }
          .then { |p| apply_multi_flag(p, multi_attrs) }
          .then { |p| apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end
    end

    def dsl_attrs_for(prop, dsl_attrs)
      dsl_attrs[prop.column_name.to_sym] || dsl_attrs[prop.name.to_sym]
    end

    def apply_dsl_type(prop, dsl_attrs)
      dsl_type = dsl_attrs_for(prop, dsl_attrs)
      return prop unless dsl_type&.any?

      dsl_type = resolve_class_type(dsl_type)
      prop.with(**dsl_type)
    end

    def resolve_class_type(attrs)
      type = attrs[:type]

      case type
      when Array
        resolve_union_class_types(attrs)
      when String, Symbol
        resolve_single_class_type(attrs)
      else
        attrs
      end
    end

    def resolve_single_class_type(attrs)
      attrs.merge(type: resolve_type_part(attrs[:type]))
    end

    def resolve_union_class_types(attrs)
      resolved = attrs[:type].map { |part| resolve_type_part(part) }
      # Unwrap single-element arrays (e.g., after null extraction from ["Serializer", null])
      attrs.merge(type: (resolved.size == 1) ? resolved.first : resolved)
    end

    def resolve_type_part(part)
      klass = Object.const_get(part.to_s)
      klass.respond_to?(:typelizer_config) ? context.interface_for(klass) : part
    rescue NameError
      part
    end

    def apply_multi_flag(prop, multi_attrs)
      return prop unless multi_attrs.include?(prop.column_name.to_sym)

      prop.with(multi: true)
    end
  end
end
