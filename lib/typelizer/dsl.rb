require "set"
require_relative "dsl/hooks"

module Typelizer
  module DSL
    # typelize_from Model
    # typelize attribute_name: ["string", "Date", optional: true, nullable: true, multi: true]

    def self.included(base)
      Typelizer.base_classes << base.to_s if base.name
      base.extend(ClassMethods)
      Hooks.install(base)
    end

    def self.extended(base)
      Typelizer.base_classes << base.to_s if base.name
      base.extend(ClassMethods)
      Hooks.install(base)
    end

    module ClassMethods
      def typelizer_config(&block)
        # Lazily initializes and memoizes the hash for local overrides at the class level.
        # This ensures that all subsequent DSL calls for this specific serializer class
        # modify the same single hash, allowing settings to be accumulated
        @serializer_overrides ||= {}

        @config_layer ||= SerializerConfigLayer.new(@serializer_overrides)
        @config_layer.instance_eval(&block) if block

        @config_layer
      end

      # save association of serializer to model
      def typelize_from(model)
        define_singleton_method(:_typelizer_model_name) { model }
      end

      # save association of serializer attributes to type
      # can be invoked multiple times
      def typelize(type = nil, type_params = {}, **attributes)
        if type
          # Parse type shortcuts like 'string?', 'string[]'
          parsed = TypeParser.parse(type)
          merged_params = parsed.merge(type_params).merge(attributes)
          actual_type = merged_params.delete(:type)
          @keyless_type = [actual_type, merged_params]
        else
          assign_type_information(:_typelizer_attributes, attributes)
        end
      end

      attr_accessor :keyless_type

      # Returns union of own + ancestors' multi attributes
      def _typelizer_multi_attributes
        result = @_typelizer_multi_attributes || Set.new
        if superclass.respond_to?(:_typelizer_multi_attributes)
          superclass._typelizer_multi_attributes | result
        else
          result
        end
      end

      # Returns own Set (initializing if needed) for writing
      def _own_typelizer_multi_attributes
        @_typelizer_multi_attributes ||= Set.new
      end

      def typelize_meta(**attributes)
        assign_type_information(:_typelizer_meta_attributes, attributes)
      end

      def store_type(attribute_name, name, options)
        ensure_type_store(attribute_name)
        instance_variable_get("@#{attribute_name}")[name.to_sym] ||= {}
        instance_variable_get("@#{attribute_name}")[name.to_sym].merge!(options)
      end

      private

      def assign_type_information(attribute_name, attributes)
        attributes.each do |name, attrs|
          next unless name

          store_type(attribute_name, name, TypeParser.parse_declaration(attrs))
        end
      end

      def ensure_type_store(attribute_name)
        instance_variable = "@#{attribute_name}"

        unless instance_variable_get(instance_variable)
          instance_variable_set(instance_variable, {})
        end

        unless respond_to?(attribute_name)
          define_singleton_method(attribute_name) do
            result = instance_variable_get(instance_variable) || {}
            if superclass.respond_to?(attribute_name)
              result.merge(superclass.send(attribute_name)) do |key, currentdef, supervaldef|
                supervaldef.merge(currentdef)
              end
            else
              result
            end
          end
        end
      end
    end

    module Disabled
      %i[typelize_from typelize typelize_meta].each do |name|
        define_method(name) { |*, **| }
      end
    end

    def self.disable!
      ClassMethods.prepend(Disabled)
    end
  end
end
