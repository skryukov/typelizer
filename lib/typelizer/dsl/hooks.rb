# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      def self.install(base)
        # Always install hooks to capture multi associations.
        # The hooks only record data to a Set, so overhead is minimal.
        if defined?(::Alba::Resource) && base.ancestors.include?(::Alba::Resource)
          require_relative "hooks/alba"
          base.singleton_class.prepend(Alba)
        elsif defined?(::ActiveModel::Serializer) && base.ancestors.include?(::ActiveModel::Serializer)
          require_relative "hooks/ams"
          base.singleton_class.prepend(AMS)
        elsif defined?(::Oj::Serializer) && base.ancestors.include?(::Oj::Serializer)
          require_relative "hooks/oj_serializers"
          base.singleton_class.prepend(OjSerializers)
        elsif defined?(::Panko::Serializer) && base.ancestors.include?(::Panko::Serializer)
          require_relative "hooks/panko"
          base.singleton_class.prepend(Panko)
        end
      end

      # Shared methods available to all hook modules
      module Methods
        private

        def consume_keyless_type(name)
          return unless keyless_type

          type, attrs = keyless_type
          store_type(:_typelizer_attributes, name, attrs.merge(type: type))
          self.keyless_type = nil
        end

        def record_multi(name)
          _own_typelizer_multi_attributes << name.to_sym
        end
      end

      # DSL for defining hooks with less boilerplate
      module Builder
        def hook(*methods, multi: false)
          methods.each do |method|
            define_method(method) do |name = nil, *args, **kwargs, &block|
              if name
                record_multi(name) if multi
                consume_keyless_type(name)
              end
              super(name, *args, **kwargs, &block)
            end
          end
        end

        def hook_method_added
          define_method(:method_added) do |method_name|
            consume_keyless_type(method_name)
            super(method_name)
          end
        end
      end
    end
  end
end
