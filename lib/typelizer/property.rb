module Typelizer
  Property = Struct.new(
    :name, :type, :optional, :nullable,
    :multi, :column_name, :column_type, :comment, :enum, :enum_type_name, :deprecated,
    :with_traits, :additional_types, :user_asserted, :inference_locked,
    # jbuilder-walker private (the column_type precedent: add-only,
    # fingerprint-excluded); other plugins must not read or set it.
    :merge_block_array,
    keyword_init: true
  ) do
    def with(**attrs)
      dup.tap { |p| attrs.each { |k, v| p[k] = v } }
    end

    def lookup_in(hash)
      hash[column_name.to_sym] || hash[name.to_sym]
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

      # Intersection members: own type & trait types & additional types.
      extra = Array(additional_types).map { |t| render_member(t, sort_order: sort_order, prefer_double_quotes: prefer_double_quotes) }
      type_str = ([type_str] + trait_type_names + extra).join(" & ")

      type_str = "Array<#{type_str}>" if multi

      # Apply union sorting to the final type string (handles Array<...> unions too)
      type_str = UnionTypeSorter.sort(type_str, sort_order)

      # Add nullable at the end (null should always be last in sorted output)
      type_str = "#{type_str} | null" if nullable

      "#{js_key(name.to_s, prefer_double_quotes)}#{"?" if optional}: #{type_str}"
    end

    def fingerprint
      # Use array format for consistent output across Ruby versions
      # (Hash#inspect format changed in Ruby 3.4).
      # column_type, user_asserted, inference_locked, and merge_block_array
      # are excluded because they only inform inference/merge behavior, not
      # output.
      # additional_types is excluded from to_h to avoid changing fingerprints
      # for properties that don't use it; when present, its rendered names are
      # merged back in (it affects generated output).
      # A non-identifier name (quoted in the rendered TS by `js_key`) changes
      # the fingerprint the same one time its rendering changed — otherwise
      # the digest short-circuit in Writer#write_file would preserve a stale
      # unquoted (invalid-TS) file forever. Identifier names keep their
      # ORIGINAL object (String or Symbol) so existing digests stay
      # byte-identical.
      quoted_name = js_key(name.to_s, false)
      hash = to_h.except(:column_type, :additional_types, :user_asserted, :inference_locked, :merge_block_array)
        .merge(type: UnionTypeSorter.sort(type_name(sort_order: :alphabetical), :alphabetical))
      hash = hash.merge(name: quoted_name) unless quoted_name == name.to_s
      if additional_types&.any?
        hash = hash.merge(additional_types: additional_types.map { |t| render_member(t) })
      end
      hash.to_a.inspect
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

    # Renders one type member (an intersection/union participant): inline
    # `Shape`s render structurally, named references (Interfaces, classes)
    # render by name, everything else by `to_s`. With the default arguments
    # this matches `Shape#to_s`, so fingerprints stay byte-identical.
    def render_member(type, sort_order: :none, prefer_double_quotes: false)
      if type.is_a?(Shape)
        type.render(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)
      elsif type.respond_to?(:name)
        type.name
      else
        type.to_s
      end
    end

    def sorted_enum_keys(sort_order)
      keys = enum.map(&:to_s)
      (sort_order == :alphabetical) ? keys.sort_by(&:downcase) : keys
    end

    # Escapes the quote character and backslashes so a name or enum value
    # containing them (e.g. a `json.set! "it's"` key) emits a valid TS string
    # literal instead of `'it's'`, which is a syntax error that breaks the
    # whole generated file. Names without those characters are byte-identical.
    def quote_string(str, prefer_double_quotes)
      quote = prefer_double_quotes ? "\"" : "'"
      escaped = str.to_s.gsub(/[\\#{quote}]/) { |char| "\\#{char}" }
      "#{quote}#{escaped}#{quote}"
    end

    # A name that isn't a valid JS identifier (e.g. "kebab-key") must be
    # quoted wherever it appears as an object key — both in rendered TS
    # property positions (`render`) and in enum runtime constants. Normal
    # identifier names pass through byte-identical.
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

      case type
      when Shape
        type.render(sort_order: sort_order, prefer_double_quotes: prefer_double_quotes)
      when Array
        type.map { |t| render_member(t) }.join(" | ")
      else
        type.respond_to?(:name) ? type.name : type&.to_s || "unknown"
      end
    end
  end
end
