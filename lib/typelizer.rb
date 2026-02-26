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

    def enabled?
      return false if ENV["DISABLE_TYPELIZER"] == "true" || ENV["DISABLE_TYPELIZER"] == "1"

      ENV["RAILS_ENV"] == "development" || ENV["RACK_ENV"] == "development" || ENV["DISABLE_TYPELIZER"] == "false"
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
      interfaces(writer_name: writer_name).to_h { |i| [i.name, OpenAPI.schema_for(i, openapi_version: openapi_version)] }
    end

    private

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
