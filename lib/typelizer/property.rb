module Typelizer
  Property = Struct.new(
    :name, :type, :optional, :nullable,
    :multi, :column_name, :comment, :enum, :enum_type_name, :deprecated,
    :with_traits,
    keyword_init: true
  ) do
    def with(**attrs)
      dup.tap { |p| attrs.each { |k, v| p[k] = v } }
    end

    def inspect
      props = to_h.merge(type: type_name).map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "<#{self.class.name} #{props}>"
    end

    def eql?(other)
      return false unless other.is_a?(self.class)

      fingerprint == other.fingerprint
    end

    # Default to_s for backward compatibility (no sorting)
    def to_s
      render(sort_order: :none)
    end

    # Renders the property as a TypeScript property string
    # @param sort_order [Symbol, Proc, nil] Sort order for union types (:none, :alphabetical, or Proc)
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String] The property string like "name?: Type1 | Type2"
    def render(sort_order: :none, prefer_double_quotes: false)
      type_str = type_name(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)

      # Handle intersection types for traits
      if with_traits&.any? && type.respond_to?(:name)
        trait_types = with_traits.map { |t| "#{type.name}#{t.to_s.camelize}Trait" }
        type_str = ([type_str] + trait_types).join(" & ")
      end

      type_str = "Array<#{type_str}>" if multi

      # Apply union sorting to the final type string (handles Array<...> unions too)
      type_str = UnionTypeSorter.sort(type_str, sort_order)

      # Add nullable at the end (null should always be last in sorted output)
      type_str = "#{type_str} | null" if nullable

      "#{name}#{"?" if optional}: #{type_str}"
    end

    def fingerprint
      # Use array format for consistent output across Ruby versions
      # (Hash#inspect format changed in Ruby 3.4)
      to_h.merge(type: UnionTypeSorter.sort(type_name(sort_order: :alphabetical), :alphabetical))
        .to_a.inspect
    end

    # Generates a TypeScript type definition for named enums
    # @param sort_order [Symbol, Proc, nil] Sort order for enum values (:none, :alphabetical, or Proc)
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String, nil] The type definition like "type UserRole = 'admin' | 'user'"
    def enum_definition(sort_order: :none, prefer_double_quotes: false)
      return unless enum && enum_type_name

      values = enum.map { |v| quote_string(v.to_s, prefer_double_quotes) }
      values = values.sort_by(&:downcase) if sort_order == :alphabetical
      "type #{enum_type_name} = #{values.join(" | ")}"
    end

    private

    def quote_string(str, prefer_double_quotes)
      prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    # Returns the type name, optionally sorting union members
    # @param sort_order [Symbol, Proc, nil] Sort order for union types
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String] The type name
    def type_name(sort_order: :none, prefer_double_quotes: false)
      # If enum_type_name is set, use it (named enum type)
      return enum_type_name if enum_type_name

      if enum
        # Sort enum values if alphabetical sorting is requested
        enum_values = enum.map { |v| quote_string(v.to_s, prefer_double_quotes) }
        enum_values = enum_values.sort_by(&:downcase) if sort_order == :alphabetical
        return enum_values.join(" | ")
      end

      type.respond_to?(:name) ? type.name : type || "unknown"
    end
  end
end
