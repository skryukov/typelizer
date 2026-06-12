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
        if prop.additional_types&.any?(Shape)
          prop = prop.with(additional_types: prop.additional_types.map { |t|
            t.is_a?(Shape) ? Shape.new(properties: transform_properties(t.properties)) : t
          })
        end
        next prop unless prop.type.is_a?(Shape)

        prop.with(type: Shape.new(properties: transform_properties(prop.type.properties)))
      end
    end

    # Inline `Shape`s appear both as a property's own type and as trailing
    # intersection members (`additional_types`, e.g. a jbuilder mixed
    # composed-partial block) — both run through the same inference.
    def infer_nested_property_types(prop)
      if prop.additional_types&.any?(Shape)
        prop = prop.with(additional_types: prop.additional_types.map { |t|
          t.is_a?(Shape) ? infer_shape_types(t) : t
        })
      end
      return prop unless prop.type.is_a?(Shape)

      prop.with(type: infer_shape_types(prop.type))
    end

    def infer_shape_types(shape)
      shape.map_properties do |sub_prop|
        sub_prop
          .then { |p| p.type ? p : apply_model_inference(p) }
          .then { |p| apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end
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
