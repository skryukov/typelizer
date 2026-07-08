# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Validation and materialization of `typelize:` overrides — the
        # user's escape hatch for pinning a property's TS type. Stateless
        # except `property_from_override`, which builds through the host's
        # `build_property`; `include`d into Walker.
        module TypelizeOverride
          # `typelize:` is honored only for a literal type *string* — the
          # documented form, e.g. `typelize: "{ id: number }"` (a Symbol is
          # accepted as a bare type name). A Ruby hash/array value can't be
          # turned into a TS type by TypeParser, so it falls through to the
          # non-literal warning instead of stringifying into a broken type.
          def literal_override?(value)
            value.is_a?(String) || value.is_a?(Symbol)
          end

          DELIMITER_PAIRS = {"{" => "}", "[" => "]", "(" => ")", "<" => ">"}.freeze
          private_constant :DELIMITER_PAIRS

          # Cheap syntactic sanity check for a `typelize:` string: unbalanced
          # brackets/braces/quotes. Skips quoted content (string-literal types
          # may contain brackets), a backslash-escaped quote inside a string
          # (`'don\'t'` stays open), and the `>` of `=>` arrows.
          def unbalanced_override?(override)
            stack = []
            quote = nil
            prev = nil
            escaped = false
            override.to_s.each_char do |ch|
              if quote
                if escaped
                  escaped = false
                elsif ch == "\\"
                  escaped = true
                elsif ch == quote
                  quote = nil
                end
              elsif ch == "'" || ch == '"' || ch == "`"
                quote = ch
              elsif DELIMITER_PAIRS.key?(ch)
                stack << DELIMITER_PAIRS[ch]
              elsif DELIMITER_PAIRS.value?(ch)
                arrow = ch == ">" && prev == "="
                return true if !arrow && stack.pop != ch
              end
              prev = ch
            end
            !stack.empty? || !quote.nil?
          end

          # Routes `typelize:` overrides through TypeParser so shortcuts
          # (`string?`, `number[]`) expand into real TS. Flagged `user_asserted`
          # so `Interface#infer_types` skips model inference for this exact
          # property at this nesting level. Optionality merges the assertion
          # (`string?`) with structural optionality so `merge_branches` can widen.
          def property_from_override(name, override, optional:)
            parsed = TypeParser.parse_declaration(override)
            build_property(
              name,
              type: parsed[:type] || override.to_s,
              nullable: parsed[:nullable] || false,
              multi: parsed[:multi] || false,
              optional: optional || parsed[:optional] || false,
              user_asserted: true
            )
          end
        end
      end
    end
  end
end
