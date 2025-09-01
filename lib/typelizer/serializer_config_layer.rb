# frozen_string_literal: true

module Typelizer
  # SerializerConfigLayer
  #
  # Lightweight, validated container for per-serializer overrides defined via the DSL.
  #
  # - Backed by a plain Hash for cheap deep-merge later (see WriterContext).
  # - Only keys from Config.members are allowed; unknown keys raise NoMethodError.
  # - Supports flat setters/getters in the DSL (e.g., c.null_strategy = :nullable_and_optional).
  # - Mutable only via the DSL; #to_h returns a frozen hash to prevent external mutation.
  #
  # Rationale: we don't allocate another Config here; this layer is merged on top of
  # library/global/writer settings when computing the effective config.
  class SerializerConfigLayer
    VALID_KEYS = Config.members.to_set

    def initialize(target_hash)
      @target_hash = target_hash
    end

    def to_h
      @target_hash.dup.freeze
    end

    private

    def method_missing(name, *args)
      name = name.to_s
      key = name.chomp("=").to_sym

      raise NoMethodError, "Unknown configuration key: '#{key}'" unless VALID_KEYS.include?(key)

      return @target_hash[key] = args.first if name.end_with?("=") && args.length == 1

      return @target_hash[key] if args.empty?

      super
    end

    def respond_to_missing?(name, include_private = false)
      VALID_KEYS.include?(name.to_s.chomp("=").to_sym) || super
    end
  end
end
