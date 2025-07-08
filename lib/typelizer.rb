# frozen_string_literal: true

require_relative "typelizer/version"
require_relative "typelizer/config"
require_relative "typelizer/property"
require_relative "typelizer/interface"
require_relative "typelizer/renderer"
require_relative "typelizer/writer"
require_relative "typelizer/generator"

require_relative "typelizer/dsl"

require_relative "typelizer/serializer_plugins/auto"
require_relative "typelizer/serializer_plugins/oj_serializers"
require_relative "typelizer/serializer_plugins/alba"
require_relative "typelizer/serializer_plugins/ams"
require_relative "typelizer/serializer_plugins/panko"

require_relative "typelizer/model_plugins/active_record"
require_relative "typelizer/model_plugins/poro"
require_relative "typelizer/model_plugins/auto"

require_relative "typelizer/railtie" if defined?(Rails)

require "logger"

module Typelizer
  class << self
    def enabled?
      return false if ENV["DISABLE_TYPELIZER"] == "true" || ENV["DISABLE_TYPELIZER"] == "1"

      ENV["RAILS_ENV"] == "development" || ENV["RACK_ENV"] == "development" || ENV["DISABLE_TYPELIZER"] == "false"
    end

    attr_accessor :dirs
    attr_accessor :reject_class
    attr_accessor :logger
    attr_accessor :listen

    # @private
    attr_reader :base_classes, :additional_writers

    def configure
      yield Config
    end

    # Registers an additional writer with its own configuration
    #
    # This yields a complete copy of the base configuration, which can then be
    # modified for this specific writer. A unique `output_dir` is required.
    def add_writer
      base_config = Config.instance
      config = base_config.dup

      config.type_mapping = base_config.type_mapping.dup
      config.types_global = base_config.types_global.dup
      config.plugin_configs = base_config.plugin_configs.dup

      yield config if block_given?

      raise ArgumentError, "output_dir must be set for additional writer" unless config.output_dir

      existing_dirs = [Config.output_dir, *@additional_writers.map(&:output_dir)]

      if existing_dirs.include?(config.output_dir)
        raise ArgumentError, "output_dir '#{config.output_dir}' is already used by another writer"
      end

      @additional_writers << config

      config
    end

    def reset_writers
      additional_writers.clear
    end

    private

    attr_writer :base_classes
  end

  @additional_writers = []

  # Set in the Railtie
  self.dirs = []
  self.reject_class = ->(serializer:) { false }
  self.logger = Logger.new($stdout, level: :info)
  self.listen = nil

  self.base_classes = Set.new
end
