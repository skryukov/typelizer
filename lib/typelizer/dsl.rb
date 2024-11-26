module Typelizer
  module DSL
    # typelize_from Model
    # typelize attribute_name: ["string", "Date", optional: true, nullable: true, multi: true]

    def self.included(base)
      Typelizer.base_classes << base.to_s if base.name
      base.extend(ClassMethods)
    end

    def self.extended(base)
      Typelizer.base_classes << base.to_s if base.name
      base.extend(ClassMethods)
    end

    module ClassMethods
      def typelizer_config
        @typelizer_config ||=
          begin
            parent_config = superclass.respond_to?(:typelizer_config) ? superclass.typelizer_config : Config
            Config.new(parent_config.to_h.transform_values(&:dup))
          end
        yield @typelizer_config if block_given?
        @typelizer_config
      end

      def typelizer_interface
        @typelizer_interface ||= Interface.new(serializer: self)
      end

      # save association of serializer to model
      def typelize_from(model)
        return unless Typelizer.enabled?

        define_singleton_method(:_typelizer_model_name) { model }
      end

      # save association of serializer attributes to type
      # can be invoked multiple times
      def typelize(type = nil, type_params = {}, **attributes)
        if type
          @keyless_type = [type, type_params.merge(attributes)]
        else
          assign_type_information(:_typelizer_attributes, attributes)
        end
      end

      attr_accessor :keyless_type

      def typelize_meta(**attributes)
        assign_type_information(:_typelizer_meta_attributes, attributes)
      end

      private

      def assign_type_information(attribute_name, attributes)
        return unless Typelizer.enabled?

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

        attributes.each do |name, attrs|
          next unless name

          attrs = [attrs] if attrs && !attrs.is_a?(Array)
          options = attrs.last.is_a?(Hash) ? attrs.pop : {}

          options[:type] = attrs.join(" | ") if attrs.any?
          instance_variable_get(instance_variable)[name.to_sym] ||= {}
          instance_variable_get(instance_variable)[name.to_sym].merge!(options)
        end
      end
    end
  end
end
