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

    def transform_properties(props)
      return props unless config.properties_transformer

      props = config.properties_transformer.call(props)
      props.map do |prop|
        next prop unless prop.type.is_a?(Shape)

        prop.with(type: Shape.new(properties: transform_properties(prop.type.properties)))
      end
    end

    def infer_nested_property_types(prop)
      return prop unless prop.type.is_a?(Shape)

      inferred = prop.type.map_properties do |sub_prop|
        sub_prop
          .then { |p| p.type ? p : apply_model_inference(p) }
          .then { |p| apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end
      prop.with(type: inferred)
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
