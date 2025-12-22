# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Alba::TraitInterface
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
          infer_types(props, typelizes).sort_by { |p| p.name.to_s }
        end
      end

      private

      def infer_types(props, typelizes)
        props.map do |prop|
          # First check for typelize DSL in the trait
          dsl_type = typelizes[prop.column_name.to_sym]
          if dsl_type&.any?
            next Property.new(prop.to_h.merge(dsl_type)).tap do |property|
              property.comment ||= model_plugin.comment_for(property) if config.comments && property.comment != false
              property.enum ||= model_plugin.enum_for(property) if property.enum != false
            end
          end

          # Fall back to model plugin for type inference
          model_plugin.infer_types(prop)
        end
      end

      def model_class
        return serializer._typelizer_model_name if serializer.respond_to?(:_typelizer_model_name)

        config.instance_exec(serializer, &config.serializer_model_mapper)
      rescue NameError
        nil
      end

      def model_plugin
        @model_plugin ||= config.model_plugin.new(model_class: model_class, config: config)
      end
    end
  end
end
