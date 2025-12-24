# frozen_string_literal: true

module Typelizer
  module PropertySorter
    def self.sort(props, sort_order)
      case sort_order
      when :none, nil
        props
      when :alphabetical
        props.sort_by { |p| p.name.to_s.downcase }
      when :id_first_alphabetical
        props.sort_by { |p| [(p.name.to_s.downcase == "id") ? 0 : 1, p.name.to_s.downcase] }
      when Proc
        result = sort_order.call(props)
        result.is_a?(Array) ? result : props
      else
        props
      end
    rescue => e
      Typelizer.logger.warn("PropertySorter error: #{e.message}, preserving original order")
      props
    end
  end
end
