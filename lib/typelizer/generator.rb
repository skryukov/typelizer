# frozen_string_literal: true

module Typelizer
  class Generator
    def self.call(**args)
      new.call(**args)
    end

    def call(force: false)
      return [] unless Typelizer.enabled?

      Typelizer.configuration.writers.each do |writer_name, writer_config|
        interfaces = Typelizer.interfaces(writer_name: writer_name)
        next if interfaces.empty?

        Writer.new(writer_config).call(interfaces, force: force)
      end
    end
  end
end
