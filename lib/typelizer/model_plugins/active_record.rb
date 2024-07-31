module Typelizer
  module ModelPlugins
    class ActiveRecord
      def initialize(model_class:, config:)
        @columns_hash = model_class&.columns_hash || {}
        @config = config
      end

      attr_reader :columns_hash, :config

      def infer_types(prop)
        column = columns_hash[prop.column_name.to_s]
        return prop unless column

        prop.multi = !!column.try(:array)
        case config.null_strategy
        when :nullable
          prop.nullable = column.null
        when :optional
          prop.optional = column.null
        when :nullable_and_optional
          prop.nullable = column.null
          prop.optional = column.null
        else
          raise "Unknown null strategy: #{config.null_strategy}"
        end

        prop.type = @config.type_mapping[column.type]

        prop
      end
    end
  end
end
