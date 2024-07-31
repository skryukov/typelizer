module Typelizer
  module SerializerPlugins
    class Base
      def initialize(serializer:, config:)
        @serializer = serializer
        @config = config
      end

      def root_key
        nil
      end

      def meta_fields
        nil
      end

      def typelize_method_transform(method:, name:, binding:, type:, attrs:)
        {name => [type, attrs]}
      end

      def methods_to_typelize
        []
      end

      def properties
        []
      end

      private

      attr_reader :serializer, :config
    end
  end
end
