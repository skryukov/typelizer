# frozen_string_literal: true

require_relative "typelizer/version"
require_relative "typelizer/property"
require_relative "typelizer/model_plugins/auto"
require_relative "typelizer/serializer_plugins/auto"

require_relative "typelizer/config"
require_relative "typelizer/configuration"
require_relative "typelizer/serializer_config_layer"

require_relative "typelizer/contexts/writer_context"
require_relative "typelizer/contexts/scan_context"
require_relative "typelizer/property_sorter"
require_relative "typelizer/import_sorter"
require_relative "typelizer/interface"
require_relative "typelizer/renderer"
require_relative "typelizer/writer"
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

    private

    attr_writer :base_classes
  end

  # Set in the Railtie
  self.logger = Logger.new($stdout, level: :info)

  self.base_classes = Set.new
end
