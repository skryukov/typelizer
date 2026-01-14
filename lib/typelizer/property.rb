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
    # @return [String] The property string like "name?: Type1 | Type2"
    def render(sort_order: :none)
      type_str = type_name(sort_order: sort_order)

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
      props = to_h
      # Always use alphabetical sorting in fingerprint for deterministic change detection
      props[:type] = UnionTypeSorter.sort(type_name(sort_order: :alphabetical), :alphabetical)
      props.each_with_object(+"<#{self.class.name}") do |(k, v), fp|
        fp << " #{k}=#{v.inspect}" unless v.nil?
      end << ">"
    end

    def enum_definition
      return unless enum && enum_type_name

      "type #{enum_type_name} = #{enum.map { |v| v.to_s.inspect }.join(" | ")}"
    end

    private

    # Returns the type name, optionally sorting union members
    # @param sort_order [Symbol, Proc, nil] Sort order for union types
    # @return [String] The type name
    def type_name(sort_order: :none)
      # If enum_type_name is set, use it (named enum type)
      return enum_type_name if enum_type_name

      if enum
        # Sort enum values if alphabetical sorting is requested
        enum_values = enum.map { |v| v.to_s.inspect }
        enum_values = enum_values.sort_by(&:downcase) if sort_order == :alphabetical
        return enum_values.join(" | ")
      end

      type.respond_to?(:name) ? type.name : type || "unknown"
    end
  end
end
