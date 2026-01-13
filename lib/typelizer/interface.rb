module Typelizer
  class Interface
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
        Renderer.call("inline_type.ts.erb", properties: properties).strip
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
        all_properties = properties + trait_interfaces.flat_map(&:properties)
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
        # Include both main properties and trait properties for import collection
        all_properties = properties_to_print + trait_interfaces.flat_map(&:properties)

        association_serializers, attribute_types = all_properties.filter_map(&:type)
          .uniq
          .partition { |type| type.is_a?(Interface) }

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
      if trait_interfaces.empty?
        "<#{self.class.name} #{name} properties=[#{properties_to_print.map(&:fingerprint).join(", ")}]>"
      else
        traits_fingerprint = trait_interfaces.map { |t| "#{t.name}=[#{t.properties.map(&:fingerprint).join(", ")}]" }.join(", ")
        "<#{self.class.name} #{name} properties=[#{properties_to_print.map(&:fingerprint).join(", ")}] traits=[#{traits_fingerprint}]>"
      end
    end

    def quote(str)
      config.prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    private

    def self_type_name
      serializer.name.match(/(\w+::)?(\w+)(Serializer|Resource)/)[2]
    end

    def extract_typescript_types(type)
      type.split(/[<>\[\],\s|]+/)
    end

    def global_type?(type)
      type[0] == type[0].downcase || config.types_global.include?(type)
    end

    def infer_types(props, hash_name = :_typelizer_attributes)
      props.map do |prop|
        if serializer.respond_to?(hash_name)
          dsl_type = serializer.public_send(hash_name)[prop.column_name.to_sym]
          if dsl_type&.any?
            next Property.new(prop.to_h.merge(dsl_type)).tap do |property|
              property.comment ||= model_plugin.comment_for(property) if config.comments && property.comment != false
              property.enum ||= model_plugin.enum_for(property) if property.enum != false
            end
          end
        end

        model_plugin.infer_types(prop)
      end
    end

    def model_class
      return serializer._typelizer_model_name if serializer.respond_to?(:_typelizer_model_name)

      # Execute the `serializer_model_mapper` lambda in the context of the `config` object
      # This giving a possibility to access other lambdas, for example, `serializer_name_mapper`
      config.instance_exec(serializer, &config.serializer_model_mapper)
    rescue NameError => e
      Typelizer.logger.debug("model_mapper failed for serializer #{serializer.name}: #{e.class}: #{e.message}")

      nil
    end

    def model_plugin
      @model_plugin ||= config.model_plugin.new(model_class: model_class, config: config)
    end
  end
end
