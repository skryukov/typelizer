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

      # Post-inference hook: `Interface#properties` calls this with the final
      # property list once model inference has run. No-op by default; plugins
      # whose property sources carry no class body (e.g. jbuilder templates)
      # override it to judge unresolved `unknown` fallbacks honestly.
      def after_type_inference(props)
      end

      private

      attr_reader :serializer, :config, :context
    end
  end
end
