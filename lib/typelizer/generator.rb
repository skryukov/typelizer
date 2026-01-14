# frozen_string_literal: true

module Typelizer
  class Generator
    def self.call(**args)
      new.call(**args)
    end

    def call(force: false)
      return [] unless Typelizer.enabled?

      load_serializers
      serializers = target_serializers

      Typelizer.configuration.writers.each do |writer_name, writer_config|
        context = WriterContext.new(writer_name: writer_name)
        interfaces = serializers.map { |klass| context.interface_for(klass) }

        Writer.new(writer_config).call(interfaces, force: force)
      end

      serializers
    end

    private

    def load_serializers
      Typelizer.dirs.flat_map { |dir| Dir["#{dir}/**/*.rb"] }.each do |file|
        require file
      end
    end

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
  end
end
