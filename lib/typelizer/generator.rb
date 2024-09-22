# frozen_string_literal: true

module Typelizer
  class Generator
    def self.call
      new.call
    end

    def initialize(config = Typelizer::Config)
      @config = config
      @writer = Writer.new
    end

    attr_reader :config, :writer

    def call(force: false)
      return unless Typelizer.enabled?

      read_serializers

      interfaces = target_serializers.map(&:typelizer_interface).reject(&:empty?)
      writer.call(interfaces, force: force)

      interfaces
    end

    private

    def target_serializers
      base_classes = Typelizer.base_classes.filter_map do |base_class|
        Object.const_get(base_class) if Object.const_defined?(base_class)
      end.tap do |base_classes|
        raise ArgumentError, "Please ensure all your serializers include Typelizer::DSL." if base_classes.none?
      end

      (base_classes + base_classes.flat_map(&:descendants)).uniq
        .reject { |serializer| Typelizer.reject_class.call(serializer: serializer) }
        .sort_by(&:name)
    end

    def read_serializers(files = nil)
      files ||= Typelizer.dirs.flat_map { |dir| Dir["#{dir}/**/*.rb"] }

      files.each do |file|
        trace = TracePoint.new(:call) do |tp|
          begin
            next unless tp.self.methods.include?(:typelizer_interface)
          rescue WeakRef::RefError
            next
          end
          serializer_plugin = tp.self.typelizer_interface.serializer_plugin

          if tp.callee_id.in?(serializer_plugin.methods_to_typelize)
            type, attrs = tp.self.keyless_type
            name = tp.binding.local_variable_get(:name) if tp.binding.local_variable_defined?(:name)
            tp.self.typelize(**serializer_plugin.typelize_method_transform(method: tp.callee_id, binding: tp.binding, name: name, type: type, attrs: attrs || {}))
            tp.self.keyless_type = nil
          end
        end

        trace.enable
        require file
        trace.disable
      end
    end
  end
end
