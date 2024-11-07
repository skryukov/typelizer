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
    attr_reader :base_classes

    def configure
      yield Config
    end

    private

    attr_writer :base_classes
  end

  # Set in the Railtie
  self.dirs = []
  self.reject_class = ->(serializer:) { false }
  self.logger = Logger.new($stdout, level: :info)
  self.listen = nil

  self.base_classes = Set.new
end
