# frozen_string_literal: true

module Typelizer
  class Generator
    def self.call(**args)
      new.call(**args)
    end

    def call(force: false)
      return [] unless Typelizer.enabled?

      # plugin scan per run cache
      @scan_plugin_cache = {}

      read_serializers
      serializers = target_serializers

      # For each writer, build a dedicated WriterContext. The context holds that writer's
      # configuration and resolves the effective Config for every Interface (per serializer)
      # by merging global, writer, and per-serializer (DSL) overrides
      Typelizer.configuration.writers.each do |writer_name, writer_config|
        context = WriterContext.new(writer_name: writer_name)
        interfaces = serializers.map { |klass| context.interface_for(klass) }

        # Include any select interfaces that were created
        all_interfaces = interfaces + context.instance_variable_get(:@select_interface_cache).values

        Writer.new(writer_config).call(all_interfaces, force: force)
      end

      serializers
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
          next unless typelized_class?(tp.self)

          serializer_plugin = build_scan_plugin_for(tp.self)
          next unless serializer_plugin

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

    def typelized_class?(klass)
      klass.is_a?(Class) && klass.respond_to?(:typelizer_config)
    rescue
      false
    end

    # Builds a minimal plugin instance used only during scan time for TracePoint
    def build_scan_plugin_for(serializer_klass)
      return @scan_plugin_cache[serializer_klass] if @scan_plugin_cache&.key?(serializer_klass)

      base = Typelizer.configuration.writer_config(:default)
      local_configuration = serializer_klass.typelizer_config.to_h.slice(:serializer_plugin, :plugin_configs)
      cfg = base.with_overrides(**local_configuration)

      @scan_plugin_cache[serializer_klass] = cfg.serializer_plugin.new(
        serializer: serializer_klass,
        config: cfg,
        context: Typelizer::ScanContext
      )
    rescue NameError
      nil
    end
  end
end
