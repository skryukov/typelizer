# frozen_string_literal: true

module Typelizer
  module TypeInference
    private

    def apply_model_inference(prop)
      model_plugin.infer_types(prop)
    end

    def apply_metadata(prop)
      prop.tap do |p|
        p.comment ||= model_plugin.comment_for(p) if config.comments && p.comment != false
        p.enum ||= model_plugin.enum_for(p) if p.enum != false
      end
    end

    def infer_nested_property_types(prop)
      return prop unless prop.nested_properties&.any?

      typelizes = prop.nested_typelizes || {}
      inferred = prop.nested_properties.map do |sub_prop|
        dsl_type = typelizes[sub_prop.column_name.to_sym] || typelizes[sub_prop.name.to_sym]
        sub_prop
          .then { |p| dsl_type&.any? ? p.with(**dsl_type) : apply_model_inference(p) }
          .then { |p| apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end

      prop.with(nested_properties: inferred)
    end

    def model_class
      return serializer._typelizer_model_name if serializer.respond_to?(:_typelizer_model_name)

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
