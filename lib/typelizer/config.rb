module Typelizer
  TYPE_MAPPING = {
    boolean: :boolean,
    date: :string,
    datetime: :string,
    decimal: :number,
    integer: :number,
    string: :string,
    text: :string,
    citext: :string
  }.tap do |types|
    types.default = :unknown
  end

  class Config < Struct.new(
    :serializer_name_mapper,
    :serializer_model_mapper,
    :properties_transformer,
    :model_plugin,
    :serializer_plugin,
    :plugin_configs,
    :type_mapping,
    :null_strategy,
    :output_dir,
    :types_import_path,
    :types_global,
    keyword_init: true
  ) do
    class << self
      def instance
        @instance ||= new(
          serializer_name_mapper: ->(serializer) do
            return "" if serializer.name.nil?

            serializer.name.ends_with?("Serializer") ? serializer.name&.delete_suffix("Serializer") : serializer.name&.delete_suffix("Resource")
          end,
          serializer_model_mapper: ->(serializer) do
            base_class = serializer_name_mapper.call(serializer)
            Object.const_get(base_class) if Object.const_defined?(base_class)
          end,

          model_plugin: ModelPlugins::Auto,
          serializer_plugin: SerializerPlugins::Auto,
          plugin_configs: {},

          type_mapping: TYPE_MAPPING,
          null_strategy: :nullable,

          output_dir: js_root.join("types/serializers"),

          types_import_path: "@/types",
          types_global: %w[Array Date Record File FileList],

          properties_transformer: nil
        )
      end

      private

      def js_root
        root_path = defined?(Rails) ? Rails.root : Pathname.pwd
        js_root = defined?(ViteRuby) ? ViteRuby.config.source_code_dir : "app/javascript"
        root_path.join(js_root)
      end

      def respond_to_missing?(name, include_private = false)
        Typelizer.respond_to?(name) ||
          instance.respond_to?(name, include_private)
      end

      def method_missing(method, *args, &block)
        return Typelizer.send(method, *args, &block) if Typelizer.respond_to?(method)

        instance.send(method, *args, &block)
      end
    end
  end
  end
end
