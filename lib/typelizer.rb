# frozen_string_literal: true

require_relative "typelizer/version"
require_relative "typelizer/union_type_sorter"
require_relative "typelizer/property"
require_relative "typelizer/model_plugins/auto"
require_relative "typelizer/serializer_plugins/auto"

require_relative "typelizer/config"
require_relative "typelizer/configuration"
require_relative "typelizer/serializer_config_layer"

require_relative "typelizer/contexts/writer_context"
require_relative "typelizer/property_sorter"
require_relative "typelizer/import_sorter"
require_relative "typelizer/interface"
require_relative "typelizer/renderer"
require_relative "typelizer/writer"
require_relative "typelizer/openapi"
require_relative "typelizer/generator"
require_relative "typelizer/route_config"
require_relative "typelizer/route_generator"
require_relative "typelizer/route_writer"
require_relative "typelizer/type_parser"
require_relative "typelizer/dsl"

require_relative "typelizer/serializer_plugins/oj_serializers"
require_relative "typelizer/serializer_plugins/alba"
require_relative "typelizer/serializer_plugins/ams"
require_relative "typelizer/serializer_plugins/panko"

require_relative "typelizer/model_plugins/active_record"
require_relative "typelizer/model_plugins/poro"

require_relative "typelizer/railtie" if defined?(Rails)

require "logger"
require "forwardable"

module Typelizer
  class << self
    extend Forwardable

    # readers
    def_delegators :configuration, :dirs, :reject_class, :listen, :writer

    # writers
    def_delegators :configuration, :dirs=, :reject_class=, :listen=

    # Is Typelizer active?
    #
    # Precedence: TYPELIZER env var > development? detection
    # Legacy DISABLE_TYPELIZER is mapped to TYPELIZER with a deprecation warning.
    def enabled?
      migrate_legacy_env!

      val = ENV["TYPELIZER"]
      return val == "true" || val == "1" if val

      development?
    end

    attr_accessor :logger

    # @private
    attr_reader :base_classes

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def interfaces(writer_name: nil)
      load_serializers
      context = WriterContext.new(writer_name: writer_name)
      target_serializers(context.writer_config.reject_class)
        .map { |klass| context.interface_for(klass) }
        .reject(&:empty?)
    end

    def openapi_schemas(writer_name: nil, openapi_version: "3.0")
      result = {}
      interfaces(writer_name: writer_name).each do |i|
        result[i.name] = OpenAPI.schema_for(i, openapi_version: openapi_version)
        i.trait_interfaces.each do |trait|
          result[trait.name] = OpenAPI.schema_for(trait, openapi_version: openapi_version)
        end
      end
      result
    end

    private

    def development?
      return Rails.env.development? if defined?(Rails) && Rails.respond_to?(:env)

      ENV["RAILS_ENV"] == "development" || ENV["RACK_ENV"] == "development"
    end

    # Maps legacy DISABLE_TYPELIZER to TYPELIZER with a deprecation warning.
    # Only takes effect if TYPELIZER is not already set.
    def migrate_legacy_env!
      return if @legacy_env_migrated
      @legacy_env_migrated = true

      val = ENV["DISABLE_TYPELIZER"]
      return unless val

      new_val = (val == "true" || val == "1") ? "false" : "true"
      logger.warn(
        "[Typelizer] DISABLE_TYPELIZER is deprecated, use TYPELIZER=#{new_val} instead."
      )
      ENV["TYPELIZER"] ||= new_val
    end

    def load_serializers
      dirs.flat_map { |dir| Dir["#{dir}/**/*.rb"] }.each { |file| require file }
    end

    def target_serializers(reject_class)
      resolved = base_classes.filter_map do |base_class|
        Object.const_get(base_class) if Object.const_defined?(base_class)
      end
      if base_classes.any? && resolved.none?
        logger.warn("Typelizer: No serializers found. Ensure your serializers include Typelizer::DSL.")
        return []
      end

      (resolved + resolved.flat_map(&:descendants)).uniq
        .reject { |serializer| reject_class.call(serializer: serializer) }
        .sort_by(&:name)
    end

    attr_writer :base_classes
  end

  # Set in the Railtie
  self.logger = Logger.new($stdout, level: :info)

  self.base_classes = Set.new
end

require_relative "typelizer/delegate_tracker"
