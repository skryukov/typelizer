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
      def parse_declaration(attrs, **options)
        return options.merge(attrs) if attrs.is_a?(Hash)
        return parse(attrs, **options) unless attrs.is_a?(Array)

        options = attrs.last.merge(options) if attrs.last.is_a?(Hash)
        types = attrs.reject { |t| t.is_a?(Hash) }
        return options if types.empty?

        parse((types.size == 1) ? types.first : types, **options)
      end

      def parse(type_def, **options)
        return options if type_def.nil?
        return parse_shape(type_def, **options) if type_def.is_a?(Hash)
        return parse_array(type_def, **options) if type_def.is_a?(Array)

        type_str = type_def.to_s
        return parse_union(type_str, **options) if type_str.include?("|")

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

      # Strips a trailing `?` from an attribute key, returning [clean_name, optional?].
      def parse_key(name)
        str = name.to_s
        str.end_with?("?") ? [str.chomp("?").to_sym, true] : [name.to_sym, false]
      end

      def apply_optional_key(parsed, optional_from_key)
        parsed[:optional] = true if optional_from_key && !parsed.key?(:optional)
        parsed
      end

      private

      def parse_shape(hash, **options)
        properties = hash.map do |name, value|
          clean_name, optional_from_key = parse_key(name)

          # parse_declaration returns Hash args verbatim (options-bag form); nested
          # shapes need parse to dispatch back here and build a Shape.
          parsed = value.is_a?(Hash) ? parse(value) : parse_declaration(value)
          apply_optional_key(parsed, optional_from_key)

          property_attrs = parsed.slice(*Property.members).tap { |h| h[:name] = clean_name }
          Property.new(optional: false, nullable: false, multi: false, **property_attrs)
        end

        {type: Shape.new(properties: properties)}.merge(options)
      end

      def parse_array(type_defs, **options)
        raise ArgumentError, "Empty array passed to typelize" if type_defs.empty?

        types = []
        type_defs.each do |t|
          if t.is_a?(String)
            types << :"'#{t}'"
          else
            parsed = parse(t)
            types.concat(Array(parsed[:type]))
            options[:optional] = true if parsed[:optional]
            options[:multi] = true if parsed[:multi]
            options[:nullable] = true if parsed[:nullable]
          end
        end

        options[:nullable] = true if types.delete(:null)
        wrap_type(types, **options)
      end

      def wrap_type(types, **options)
        type = (types.size == 1) ? types.first : types
        {type: type}.merge(options)
      end

      def parse_union(type_str, **options)
        parts = UnionTypeSorter.split_union_members(type_str)

        # No top-level | found — the | is nested inside brackets
        return {type: type_str.to_sym}.merge(options) if parts.size <= 1

        options[:nullable] = true if parts.delete("null")
        if parts.size == 1
          parse(parts.first, **options)
        else
          {type: parts.map(&:to_sym)}.merge(options)
        end
      end
    end
  end
end
