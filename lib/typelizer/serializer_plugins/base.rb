module Typelizer
  module SerializerPlugins
    class Base
      def initialize(serializer:, config:, context:)
        @serializer = serializer
        @config = config
        @context = context
      end

      def root_key
        nil
      end

      # When true, the generated interface is wrapped as `Array<FooData>`.
      def root_is_array
        false
      end

      def meta_fields
        nil
      end

      def properties
        []
      end

      private

      attr_reader :serializer, :config, :context
    end
  end
end
