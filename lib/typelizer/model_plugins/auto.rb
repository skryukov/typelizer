module Typelizer
  module ModelPlugins
    module Auto
      class << self
        def new(model_class:, config:)
          plugin(model_class).new(model_class: model_class, config: config)
        end

        def plugin(model_class)
          if model_class && model_class < ::ActiveRecord::Base
            ActiveRecord
          else
            Poro
          end
        end
      end
    end
  end
end
