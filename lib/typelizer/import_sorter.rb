# frozen_string_literal: true

module Typelizer
  module ImportSorter
    def self.sort(imports, sort_order)
      case sort_order
      when :none, nil
        imports
      when :alphabetical
        imports.sort_by { |i| i.to_s.downcase }
      when Proc
        result = sort_order.call(imports)
        result.is_a?(Array) ? result : imports
      else
        imports
      end
    rescue => e
      Typelizer.logger.warn("ImportSorter error: #{e.message}, preserving original order")
      imports
    end
  end
end
