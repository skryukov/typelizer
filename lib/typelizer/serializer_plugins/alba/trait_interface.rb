# frozen_string_literal: true

require_relative "../../type_inference"

module Typelizer
  module SerializerPlugins
    class Alba::TraitInterface
      include TypeInference

      attr_reader :serializer, :trait_name, :context, :plugin

      def initialize(serializer:, trait_name:, context:, plugin:)
        @serializer = serializer
        @trait_name = trait_name
        @context = context
        @plugin = plugin
      end

      def config
        context.config_for(serializer)
      end

      def name
        base_name = config.serializer_name_mapper.call(serializer).tr_s(":", "")
        "#{base_name}#{trait_name.to_s.camelize}Trait"
      end

      def properties
        @properties ||= begin
          props, typelizes = plugin.trait_properties(trait_name)
          props = infer_types(props, typelizes)
          PropertySorter.sort(props, config.properties_sort_order)
        end
      end

      private

      def infer_types(props, typelizes)
        props.map do |prop|
          dsl_type = typelizes[prop.column_name.to_sym] || typelizes[prop.name.to_sym]
          prop
            .then { |p| dsl_type&.any? ? p.with(**dsl_type) : apply_model_inference(p) }
            .then { |p| apply_metadata(p) }
            .then { |p| infer_nested_property_types(p) }
        end
      end
    end
  end
end
