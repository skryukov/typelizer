# frozen_string_literal: true

require "erb"

module Typelizer
  class Renderer
    def self.call(template, **context)
      new(template).call(**context)
    end

    def initialize(template)
      @erb = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates/#{template}")), trim_mode: "-")
    end

    def call(**context)
      b = binding
      context.each_pair do |key, value|
        b.local_variable_set(key, value)
      end
      erb.result(b)
    end

    private

    attr_reader :erb

    def indent(content, multiplier = 2)
      spaces = " " * multiplier
      content.to_s.each_line.map { |line| line.blank? ? line : "#{spaces}#{line}" }.join
    end

    def render(template, **context)
      Renderer.call(template, **context)
    end
  end
end
