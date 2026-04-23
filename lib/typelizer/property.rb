module Typelizer
  Property = Struct.new(
    :name, :type, :optional, :nullable,
    :multi, :column_name, :column_type, :comment, :enum, :enum_type_name, :deprecated,
    :with_traits, :nested_properties, :nested_typelizes,
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

    def trait_type_names
      return [] unless with_traits&.any? && type.is_a?(Interface)

      with_traits.map { |t| "#{type.name}#{t.to_s.camelize}Trait" }
    end

    # Renders the property as a TypeScript property string
    # @param sort_order [Symbol, Proc, nil] Sort order for union types (:none, :alphabetical, or Proc)
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String] The property string like "name?: Type1 | Type2"
    def render(sort_order: :none, prefer_double_quotes: false)
      type_str = type_name(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)

      trait_types = trait_type_names
      type_str = ([type_str] + trait_types).join(" & ") if trait_types.any?

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
      # Exclude fields that do not affect generated TypeScript output.
      # Exclude nested_properties/nested_typelizes from to_h to avoid changing
      # fingerprints for properties that don't use them.
      # nested_typelizes is excluded entirely as it only affects inference, not output.
      to_h.except(:column_type, :nested_properties, :nested_typelizes)
        .merge(type: UnionTypeSorter.sort(type_name(sort_order: :alphabetical), :alphabetical))
        .then { |h| nested_properties&.any? ? h.merge(nested_properties: nested_properties.map(&:fingerprint)) : h }
        .to_a.inspect
    end

    # Generates a TypeScript type definition for named enums
    # @param sort_order [Symbol, Proc, nil] Sort order for enum values (:none, :alphabetical, or Proc)
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String, nil] The type definition like "type UserRole = 'admin' | 'user'"
    def enum_definition(sort_order: :none, prefer_double_quotes: false)
      return unless enum && enum_type_name

      values = sorted_enum_keys(sort_order).map { |k| quote_string(k, prefer_double_quotes) }
      "type #{enum_type_name} = #{values.join(" | ")}"
    end

    # Generates a TypeScript runtime constant for named enums
    # @param sort_order [Symbol, Proc, nil] Sort order for enum keys (:none, :alphabetical, or Proc)
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String, nil] The const like "const UserRole = { admin: 'admin', user: 'user' } as const"
    def enum_runtime_definition(sort_order: :none, prefer_double_quotes: false)
      return unless enum && enum_type_name

      entries = sorted_enum_keys(sort_order).map { |k| "#{js_key(k, prefer_double_quotes)}: #{quote_string(k, prefer_double_quotes)}" }
      "const #{enum_type_name} = { #{entries.join(", ")} } as const"
    end

    private

    def sorted_enum_keys(sort_order)
      keys = enum.map(&:to_s)
      (sort_order == :alphabetical) ? keys.sort_by(&:downcase) : keys
    end

    def quote_string(str, prefer_double_quotes)
      prefer_double_quotes ? "\"#{str}\"" : "'#{str}'"
    end

    def js_key(str, prefer_double_quotes)
      str.match?(/\A[A-Za-z_$][\w$]*\z/) ? str : quote_string(str, prefer_double_quotes)
    end

    # Returns the type name, optionally sorting union members
    # @param sort_order [Symbol, Proc, nil] Sort order for union types
    # @param prefer_double_quotes [Boolean] Whether to use double quotes for string values
    # @return [String] The type name
    def type_name(sort_order: :none, prefer_double_quotes: false)
      # If enum_type_name is set, use it (named enum type)
      return enum_type_name if enum_type_name

      if enum
        return sorted_enum_keys(sort_order).map { |k| quote_string(k, prefer_double_quotes) }.join(" | ")
      end

      if type.nil? && nested_properties&.any?
        return Shape.new(properties: nested_properties).render(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)
      end

      case type
      when Shape
        type.render(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)
      when Array
        type.map { |t| t.respond_to?(:name) ? t.name : t.to_s }.join(" | ")
      else
        type.respond_to?(:name) ? type.name : type&.to_s || "unknown"
      end
    end
  end
end
