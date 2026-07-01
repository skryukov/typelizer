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
        map_property_shapes(prop) { |shape| Shape.new(properties: transform_properties(shape.properties)) }
      end
    end

    def infer_nested_property_types(prop)
      map_property_shapes(prop) { |shape| infer_shape_types(shape) }
    end

    # Inline `Shape`s appear both as a property's own type and as trailing
    # intersection members (`additional_types`, e.g. a jbuilder mixed
    # composed-partial block) — applies the block to every Shape in both
    # positions so transformation and inference run through the same walk.
    def map_property_shapes(prop)
      if prop.additional_types&.any?(Shape)
        prop = prop.with(additional_types: prop.additional_types.map { |t|
          t.is_a?(Shape) ? yield(t) : t
        })
      end
      return prop unless prop.type.is_a?(Shape)

      prop.with(type: yield(prop.type))
    end

    def infer_shape_types(shape)
      shape.map_properties do |sub_prop|
        sub_prop
          .then { |p| p.type ? p : apply_model_inference(p) }
          .then { |p| p.inference_locked ? p : apply_metadata(p) }
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
