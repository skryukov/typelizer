# frozen_string_literal: true

require "pathname"

module Typelizer
  TYPE_MAPPING = Hash.new(:unknown).update(
    boolean: :boolean,
    date: :string,
    datetime: :string,
    time: :string,
    decimal: :number,
    float: :number,
    integer: :number,
    string: :string,
    text: :string,
    citext: :string,
    uuid: :string
  ).freeze

  DEFAULT_TYPES_GLOBAL = %w[Array Date Record File FileList].freeze

  Config = Struct.new(
    :serializer_name_mapper,
    :serializer_model_mapper,
    :properties_transformer,
    :properties_sort_order,
    :imports_sort_order,
    :model_plugin,
    :serializer_plugin,
    :plugin_configs,
    :type_mapping,
    :null_strategy,
    :output_dir,
    :types_import_path,
    :types_global,
    :verbatim_module_syntax,
    :inheritance_strategy,
    :associations_strategy,
    :comments,
    :prefer_double_quotes,
    keyword_init: true
  )

  # Immutable configuration object for a single writer
  #
  # Use .build to construct from defaults, and #with_overrides to copy with overrides.
  class Config
    # Returns library defaults (built-in) for building a Config.
    # This method creates a fresh Hash each time to avoid sharing mutable state
    # across builds
    def self.defaults
      {
        serializer_name_mapper: lambda do |serializer|
          name = serializer.name.to_s

          return name if name.empty?

          # remove only the end of the line
          name.sub(/(Serializer|Resource)\z/, "")
        end,

        serializer_model_mapper: lambda do |serializer|
          base_class = serializer_name_mapper.call(serializer)
          Object.const_get(base_class) if Object.const_defined?(base_class)
        end,

        model_plugin: ModelPlugins::Auto,
        serializer_plugin: SerializerPlugins::Auto,
        plugin_configs: {}.freeze,
        type_mapping: TYPE_MAPPING,
        null_strategy: :nullable,
        inheritance_strategy: :none,
        associations_strategy: :database,
        comments: false,
        prefer_double_quotes: false,

        output_dir: -> { default_output_dir },

        types_import_path: "@/types",
        types_global: DEFAULT_TYPES_GLOBAL,
        properties_transformer: nil,
        properties_sort_order: :none,
        imports_sort_order: :none,
        verbatim_module_syntax: false
      }
    end

    def self.build(**overrides)
      new(**defaults.merge(overrides))
    end

    def self.default_output_dir
      root_path = defined?(Rails) ? Rails.root : Pathname.pwd
      js_root = defined?(ViteRuby) ? ViteRuby.config.source_code_dir : "app/javascript"

      root_path.join(js_root, "types/serializers")
    end

    def with_overrides(**overrides)
      props = to_h
      props.merge!(overrides) unless overrides.empty?

      self.class.new(**props)
    end

    def output_dir
      v = self[:output_dir]
      v.respond_to?(:call) ? v.call : v
    end
  end
end
