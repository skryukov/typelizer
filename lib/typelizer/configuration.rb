# frozen_string_literal: true

require "set"
require "pathname"

module Typelizer
  # Central registry for Typelizer multi-writer configuration
  #
  # Responsibilities:
  # - Holds immutable Config per writer name (always includes :default)
  # - Maintain flat DSL setters for :default (e.g., config.output_dir = ...)
  # - Allows defining/updating named writers via writer(:name) { |cfg| ... }
  # - Check unique output_dir across writers to avoid file conflicts
  #
  # Config priorities:
  # - WriterContext merges in order: library defaults < global_settings < writer < DSL inheritance
  # - global_settings are only updated by flat setters, not by writer(:default) blocks
  class Configuration
    DEFAULT_WRITER_NAME = :default

    attr_accessor :dirs, :reject_class, :listen
    attr_reader :writers, :global_settings

    def initialize
      @dirs = []
      @reject_class = ->(serializer:) { false }
      @listen = nil

      default = Config.build

      @writers = {DEFAULT_WRITER_NAME => default.freeze}
      @global_settings = {}

      @writer_output_dirs = {DEFAULT_WRITER_NAME => normalize_path(default.output_dir)}
      @used_output_dirs = Set.new(@writer_output_dirs.values.compact)
    end

    # Defines or updates a writer configuration.
    #
    # Inherits from the existing writer config (or global_settigns if absent), yields a mutable copy,
    # then freezes and stores it. output_dir is unique and mandatory
    # Also accepts "from" argument, which allows us to inherit configuration from any writer
    def writer(name = DEFAULT_WRITER_NAME, from: nil, &block)
      writer_name = normalize_writer_name(name)

      # Inherit from existing writer config or from "from" attribute or global (flatt) config
      base_config =
        if @writers.key?(writer_name)
          @writers[writer_name]
        elsif from && @writers.key?(from.to_sym)
          @writers[from.to_sym]
        else
          Config.build(**@global_settings)
        end

      mutable_config = base_config.with_overrides

      block&.call(mutable_config)

      # Register output directory for uniqueness checking
      register_output_dir!(writer_name, mutable_config.output_dir)

      # Store and return frozen configuration
      @writers[writer_name] = mutable_config.freeze
    end

    def writer_config(name = DEFAULT_WRITER_NAME)
      @writers.fetch((name || DEFAULT_WRITER_NAME).to_sym)
    end

    # Reset writers and keep only `default` writer
    def reset_writers!
      @writers.keep_if { |key, _| key == DEFAULT_WRITER_NAME }

      @writer_output_dirs = {
        DEFAULT_WRITER_NAME => normalize_path(@writers[DEFAULT_WRITER_NAME].output_dir)
      }

      @used_output_dirs = Set.new(@writer_output_dirs.values.compact)
    end

    private

    # Setters and readers to Writer(:default) config
    # Keep the "flat" setters for the :default writer, for example:
    #   config.output_dir = ...
    #   config.prefer_double_quotes = true
    def method_missing(name, *args, &block)
      name = name.to_s
      config_key = normalize_method_name(name)

      # Setters
      if name.end_with?("=") && args.length.positive?
        return super unless config_attribute?(config_key)

        val = args.first
        new_default = @writers[DEFAULT_WRITER_NAME].with_overrides(config_key => val)

        register_output_dir!(DEFAULT_WRITER_NAME, new_default.output_dir) if config_key == :output_dir

        @writers[DEFAULT_WRITER_NAME] = new_default.freeze

        return @global_settings[config_key] = val
      end

      # Readers
      return @writers[DEFAULT_WRITER_NAME].public_send(config_key) if args.empty? && config_attribute?(config_key)

      super
    end

    def respond_to_missing?(name, include_private = false)
      str = name.to_s
      key = normalize_method_name(str)
      (config_attribute?(key) && (str.end_with?("=") || true)) || super
    end

    # Normalizes and validates writer name
    def normalize_writer_name(name)
      writer_name = (name || DEFAULT_WRITER_NAME).to_sym

      raise ArgumentError, "Writer name cannot be empty" if writer_name.to_s.strip.empty?

      writer_name
    end

    # Validates and registers output directory for uniqueness across writers
    def register_output_dir!(writer_name, dir)
      raise ArgumentError, "output_dir must be configured for writer :#{writer_name}" if dir.to_s.strip.empty?

      path = normalize_path(dir)

      current = @writer_output_dirs[writer_name]
      return if current == path

      if @writer_output_dirs.any? { |k, v| k != writer_name && v == path }
        holder = @writer_output_dirs.key(path)

        raise ArgumentError, "output_dir '#{path}' is already in use by writer :#{holder}"
      end

      @used_output_dirs.delete(current) if current
      @writer_output_dirs[writer_name] = path
      @used_output_dirs << path
    end

    def normalize_path(dir)
      Pathname(dir).expand_path.to_s
    end

    def normalize_method_name(name)
      name.to_s.chomp("=").to_sym
    end

    def config_attribute?(name)
      Config.members.include?(name)
    end
  end
end
