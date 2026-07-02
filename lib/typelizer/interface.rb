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
      elsif (override = type_name_override)
        override
      else
        config.serializer_name_mapper.call(serializer).tr_s(":", "")
      end
    end

    # Per-serializer name override declared via `typelize_as "Foo"`, which
    # defines `_typelizer_type_name` on the class. jbuilder templates support
    # `typelize_as` too, but bind it as the generated `Templates::` constant
    # name (resolved through the template's own `serializer_name_mapper`), so
    # they resolve their name below instead of through this override.
    def type_name_override
      return nil unless serializer.respond_to?(:_typelizer_type_name)
      serializer._typelizer_type_name
    end

    def filename
      if config.filename_mapper
        config.filename_mapper.call(config.serializer_name_mapper.call(serializer))
      else
        name.gsub("::", "/")
      end
    end

    def index_path(index_dir)
      iface_dir = config.output_dir.to_s
      if iface_dir != index_dir
        Pathname.new(File.join(iface_dir, filename)).relative_path_from(Pathname.new(index_dir)).to_s
      else
        "./#{filename}"
      end
    end

    def root_key
      serializer_plugin.root_key
    end

    # Human-readable origin of this interface for warnings: the template
    # path for jbuilder-template-backed serializers, the class name
    # otherwise.
    def source_description
      if serializer.respond_to?(:_template_path)
        serializer._template_path.to_s
      else
        serializer.name.to_s
      end
    end

    # Feature-detected (like `trait_interfaces`) so duck-typed third-party
    # plugins that don't inherit from SerializerPlugins::Base keep working.
    def root_is_array
      serializer_plugin.respond_to?(:root_is_array) && serializer_plugin.root_is_array
    end

    # A root-array template whose element type resolved to a NAMED interface
    # (jbuilder `json.array! @xs, partial: "xs/x"`): rendering references —
    # and imports — that name (`type X = Array<Element>;`) instead of
    # inlining a `...Data` alias. May also be a plain type string (e.g.
    # "unknown" for an unresolvable element). Feature-detected like
    # `root_is_array` so duck-typed plugins keep working.
    def root_array_element
      return nil unless serializer_plugin.respond_to?(:root_array_element)

      serializer_plugin.root_array_element
    end

    def root_array_element_name
      case (element = root_array_element)
      when Interface then element.name
      when String then element
      end
    end

    def wrapped?
      root_key || root_is_array
    end

    def empty?
      # A named-element root array carries no own properties, but its
      # `type X = Array<Element>;` alias is real output — never drop it.
      meta_fields.empty? && properties.empty? && root_array_element_name.nil?
    end

    def meta_fields
      @meta_fields ||= begin
        props = serializer_plugin.meta_fields || []
        props = infer_types(props, :_typelizer_meta_attributes)
        props = transform_properties(props)
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
        # Post-inference hook: plugins whose property sources carry no class
        # body (e.g. jbuilder templates) can only judge an `unknown` fallback
        # honestly AFTER model inference had its chance to fill types in.
        # Feature-detected for duck-typed plugins (trait_interfaces pattern).
        serializer_plugin.after_type_inference(props) if serializer_plugin.respond_to?(:after_type_inference)
        props = transform_properties(props)
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

        flat_types = (all_properties.filter_map(&:type) + all_properties.flat_map { |p| p.additional_types || [] })
          .flat_map { |t| flatten_type_members(t) }
          .uniq
        association_serializers, attribute_types = flat_types.partition { |type| type.is_a?(Interface) }

        serializer_types = association_serializers
          .filter_map { |interface| interface.name if interface.name != name && !interface.inline? }

        custom_type_imports = attribute_types
          .flat_map { |type| extract_typescript_types(type.to_s) }
          .uniq
          .reject { |type| global_type?(type) }

        trait_imports = all_properties.flat_map do |prop|
          next [] if prop.type.is_a?(Interface) && prop.type.name == name

          prop.trait_type_names
        end

        # Collect enum type names from properties
        enum_imports = all_properties.filter_map(&:enum_type_name)

        result = (custom_type_imports + serializer_types + trait_imports + enum_imports +
          Array(parent_interface&.name) + Array(root_array_element_import)).uniq - [self_type_name, name]
        ImportSorter.sort(result, config.imports_sort_order)
      end
    end

    def inspect
      "<#{self.class.name} #{name} properties=#{properties.inspect}>"
    end

    def fingerprint
      parts = [
        name,
        properties_to_print.map(&:fingerprint),
        parent_interface&.name,
        root_key,
        meta_fields.map(&:fingerprint),
        trait_interfaces.map { |t| [t.name, t.properties.map(&:fingerprint)] },
        CONFIGS_AFFECTING_OUTPUT.map { |key| config.public_send(key) }
      ]
      # Appended only for root arrays, so non-array interfaces keep the exact
      # fingerprint they had before jbuilder existed — no digest churn for
      # existing serializers on upgrade.
      parts << [:root_array, root_array_element_name || true] if root_is_array
      parts.inspect
    end

    def quote(str)
      config.prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    private

    def collect_all_properties(props)
      props.flat_map do |prop|
        children = ([prop.type] + Array(prop.additional_types))
          .flat_map { |type| nested_properties_of(type) }
        children.any? ? [prop] + collect_all_properties(children) : [prop]
      end
    end

    # Structural recursion into every type that can carry nested properties:
    # inline Shapes, inline Interfaces, union members (Array — the walker's
    # same-level fold), and the walker's lazy ArrayOf element (itself a
    # Shape, a member union, or a plain type). Import and enum collection
    # both walk through here, so an Interface referenced inside a
    # union-member Shape (or an array element Shape) is still imported.
    def nested_properties_of(type)
      case type
      when Shape then type.properties
      when Interface then type.inline? ? type.properties : []
      when Array then type.flat_map { |member| nested_properties_of(member) }
      else
        array_wrapper?(type) ? nested_properties_of(type.element) : []
      end
    end

    # Named type references reachable from a property type: splats union
    # members and looks through ArrayOf wrappers to their elements. Shapes
    # yield nothing here — their nested properties are walked structurally
    # (collect_all_properties), never string-tokenized, so a rendered
    # `{ author: User; }` body can't leak `User;` garbage into imports.
    def flatten_type_members(type)
      case type
      when Array then type.flat_map { |member| flatten_type_members(member) }
      when Shape then []
      else
        array_wrapper?(type) ? flatten_type_members(type.element) : [type]
      end
    end

    # The jbuilder walker's lazy array wrapper, matched by duck — it lives
    # in a lazily-loaded plugin file, so no constant reference from here.
    def array_wrapper?(type)
      type.respond_to?(:element) && type.respond_to?(:map_element_shape)
    end

    # The name this serializer uses to reference ITSELF in typelize
    # declarations (excluded from imports). Derived from the demodulized
    # serializer_name_mapper output — the same name the interface actually
    # exports — so it tracks whatever suffix policy the mapper applies: the
    # default mapper already strips a trailing Serializer/Resource
    # (`AResourceFoo::UserSerializer` → "User", and only trailing — a
    # leftmost scan would stop at "A(Resource…)"), while a non-stripping
    # mapper (e.g. jbuilder's demodulize) keeps the full name, so a template
    # `typelize_as "Post2Resource"` embedding a partial `typelize_as
    # "Post2"` still imports Post2 instead of subtracting it as "self".
    # Suffix-less names (jbuilder's `Templates::Post`) pass through
    # unchanged.
    def self_type_name
      config.serializer_name_mapper.call(serializer).to_s.split("::").last.to_s
    end

    # Only a named interface element needs an import; plain type strings
    # ("unknown") are global, and a self-referential element is excluded by
    # the `- [self_type_name, name]` subtraction downstream.
    def root_array_element_import
      element = root_array_element
      element.name if element.is_a?(Interface) && !element.inline?
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
        has_dsl = prop.lookup_in(dsl_attrs)&.any?

        # `inference_locked` marks a type read off a source-code literal
        # (e.g. jbuilder's `json.title 42`): a same-named model column must
        # not overwrite it, and column metadata (comments, enums) describes
        # the column's value, not the literal one.
        prop
          .then { |p| apply_dsl_type(p, dsl_attrs) }
          .then { |p| resolve_asserted_type(p) }
          .then { |p| (has_dsl || p.user_asserted || p.inference_locked) ? p : apply_model_inference(p) }
          .then { |p| apply_multi_flag(p, multi_attrs) }
          .then { |p| p.inference_locked ? p : apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end
    end

    # `user_asserted` properties (e.g. jbuilder `typelize:` kwargs) carry
    # their type directly instead of going through the class-level
    # `dsl_attrs` registry. Run them through the same class-name resolution
    # `apply_dsl_type` performs so `typelize: "PostSerializer"` still
    # resolves to an interface reference.
    def resolve_asserted_type(prop)
      return prop unless prop.user_asserted

      prop.with(**resolve_class_type(type: prop.type))
    end

    def apply_dsl_type(prop, dsl_attrs)
      dsl_type = prop.lookup_in(dsl_attrs)
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
      when Shape
        attrs.merge(type: resolve_shape(type))
      else
        attrs
      end
    end

    def resolve_shape(shape)
      shape.map_properties do |p|
        resolved = resolve_class_type(type: p.type)
        p.with(type: resolved[:type])
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
