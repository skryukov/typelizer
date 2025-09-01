# frozen_string_literal: true

module Typelizer
  # Context for a single writer during a generation pass.
  # - Caches one Interface per serializer class (prevents duplicates/loops)
  # - Computes per-serializer effective Config:
  #   library defaults < global (flat setters) < writer < DSL (parent → child)
  class WriterContext
    attr_reader :writer_config, :writer_name

    def initialize(writer_name: nil, configuration: Typelizer.configuration)
      @configuration = configuration
      @writer_name = (writer_name || Configuration::DEFAULT_WRITER_NAME).to_sym
      @writer_config = configuration.writer_config(@writer_name)

      @interface_cache = {}
      @config_cache = {}
      @dsl_cache = {}
    end

    # Returns a memoized Interface for the given serializer class within this writer context
    # Guarantees a single Interface instance per serializer (in this context), which:
    # - preserves object identity across associations,
    # - prevents infinite loops on cyclic relations,
    # - and avoids redundant recomputation
    # The cache is scoped to WriterContext (i.e., per writer and per generation run)
    def interface_for(serializer_class)
      raise ArgumentError, "Serializer class cannot be nil" if serializer_class.nil?

      @interface_cache[serializer_class] ||= Interface.new(
        serializer: serializer_class,
        context: self
      )
    end

    # Resolves the effective configuration for a serializer class by merging
    # configuration layers in priority order:
    #  Library defaults
    #  Global configuration settings
    #  Writer-specific configuration
    #  DSL configuration with inheritance (highest priority)
    def config_for(serializer_class)
      raise ArgumentError, "Serializer class cannot be nil" unless serializer_class

      @config_cache[serializer_class] ||= build_config(serializer_class)
    end

    private

    # Builds the correct configuration by merging all configuration layers
    def build_config(serializer_class)
      global_settings = @configuration.global_settings
      writer_settings = @writer_config.to_h
      dsl_settings = dsl_config_for(serializer_class)

      # Merge in priority order: global < writer < DSL
      merged_config = deep_merge(global_settings, writer_settings)
      merged_config = deep_merge(merged_config, dsl_settings)

      Config.build(**merged_config).freeze
    end

    def dsl_config_for(klass)
      return @dsl_cache[klass] if @dsl_cache.key?(klass)

      # Recursively get the parent's DSL config. If no parent or parent is not
      # a Typelizer serializer, the base is an empty hash.
      parent_dsl = (parent = klass.superclass).respond_to?(:typelizer_config) ? dsl_config_for(parent) : {}

      # Get this class's own local overrides.
      local_dsl = klass.respond_to?(:typelizer_config) ? klass.typelizer_config.to_h : {}

      @dsl_cache[klass] = deep_merge(parent_dsl, local_dsl).freeze
    end

    def deep_merge(hash_one, hash_two)
      # If Active Support's `deep_merge` exists, use it
      return hash_one.deep_merge(hash_two) if hash_one.respond_to?(:deep_merge)

      return hash_one if hash_one == hash_two
      return hash_one if hash_two.empty?
      return hash_two if hash_one.empty?

      hash_one.merge(hash_two) do |_, old_v, new_v|
        (old_v.is_a?(Hash) && new_v.is_a?(Hash)) ? deep_merge(old_v, new_v) : new_v
      end
    end
  end
end
