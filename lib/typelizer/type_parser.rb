# frozen_string_literal: true

module Typelizer
  module TypeParser
    # Regex to match type shortcuts:
    # - Base type (captured)
    # - Optional `?` modifier
    # - Optional `[]` modifier
    # Order of ? and [] can be either way
    TYPE_PATTERN = /\A(.+?)(\?)?(\[\])?(\?)?\z/

    class << self
      def parse(type_def, **options)
        return options if type_def.nil?

        type_str = type_def.to_s
        match = TYPE_PATTERN.match(type_str)

        return {type: type_def}.merge(options) unless match

        base_type = match[1]
        optional = match[2] == "?" || match[4] == "?"
        multi = match[3] == "[]"

        result = {type: base_type.to_sym}
        result[:optional] = true if optional
        result[:multi] = true if multi
        result.merge(options)
      end

      def shortcut?(type_def)
        return false if type_def.nil?

        type_str = type_def.to_s
        type_str.end_with?("?", "[]")
      end
    end
  end
end
