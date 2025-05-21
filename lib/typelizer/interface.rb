module Typelizer
  class Interface
    attr_reader :serializer, :serializer_plugin

    def config
      serializer.typelizer_config
    end

    def initialize(serializer:)
      @serializer = serializer
      @serializer_plugin = config.serializer_plugin.new(serializer: serializer, config: config)
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
        props
      end
    end

    def properties
      @properties ||= begin
        props = serializer_plugin.properties
        props = infer_types(props)
        props = config.properties_transformer.call(props) if config.properties_transformer
        props
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
      return unless serializer.superclass.respond_to?(:typelizer_interface)

      interface = serializer.superclass.typelizer_interface
      return if interface.empty?

      interface
    end

    def imports
      @imports ||= begin
        association_serializers, attribute_types = properties_to_print.filter_map(&:type)
          .uniq
          .partition { |type| type.is_a?(Interface) }

        serializer_types = association_serializers
          .filter_map { |interface| interface.name if interface.name != name && !interface.inline? }

        custom_type_imports = attribute_types
          .flat_map { |type| extract_typescript_types(type.to_s) }
          .uniq
          .reject { |type| global_type?(type) }

        (custom_type_imports + serializer_types + Array(parent_interface&.name)).uniq - Array(self_type_name)
      end
    end

    def inspect
      "<#{self.class.name} #{name} properties=#{properties.inspect}>"
    end

    def fingerprint
      "<#{self.class.name} #{name} properties=[#{properties_to_print.map(&:fingerprint).join(", ")}]>"
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

      config.serializer_model_mapper.call(serializer)
    rescue NameError
      nil
    end

    def model_plugin
      @model_plugin ||= config.model_plugin.new(model_class: model_class, config: config)
    end
  end
end
