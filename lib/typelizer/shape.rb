# frozen_string_literal: true

module Typelizer
  class Shape
    attr_reader :properties

    def initialize(properties:)
      @properties = properties.freeze
      @fingerprint = ["Shape", properties.map(&:fingerprint)].freeze
      @hash = @fingerprint.hash
      freeze
    end

    def map_properties
      self.class.new(properties: properties.map { |p| yield p })
    end

    def render(sort_order: :none, prefer_double_quotes: false)
      inner = properties.map { |p|
        (p.render(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes) + ";")
          .gsub(/^/, "  ")
      }.join("\n")
      "{\n#{inner}\n}"
    end

    alias_method :to_s, :render

    attr_reader :fingerprint, :hash

    def ==(other)
      other.is_a?(Shape) && fingerprint == other.fingerprint
    end
    alias_method :eql?, :==

    def inspect
      "<Typelizer::Shape properties=#{properties.inspect}>"
    end
  end
end
