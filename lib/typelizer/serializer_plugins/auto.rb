module Typelizer
  module SerializerPlugins
    module Auto
      class << self
        def new(serializer:, config:, context:)
          plugin(serializer).new(serializer: serializer, config: config, context: context)
        end

        def plugin(serializer)
          if defined?(::Oj::Serializer) && serializer.ancestors.include?(::Oj::Serializer)
            OjSerializers
          elsif defined?(::Alba) && serializer.ancestors.include?(::Alba::Resource)
            Alba
          elsif defined?(ActiveModel::Serializer) && serializer.ancestors.include?(ActiveModel::Serializer)
            AMS
          elsif defined?(::Panko::Serializer) && serializer.ancestors.include?(::Panko::Serializer)
            Panko
          else
            raise "Can't guess serializer plugin for #{serializer}. " \
                    "Please specify it with `config.serializer_plugin`."
          end
        end
      end
    end
  end
end
