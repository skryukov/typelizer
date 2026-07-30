# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Value-level type inference: what TS type a `json.<key> <expr>`
        # VALUE renders, judged purely from the expression's syntax —
        # literals, `Time.*` calls, ternaries, `&&`/`||` chains, safe
        # navigation, `try`/`presence`, plus the name-hint and
        # plural-name heuristics. Stateless (every judgment is a function
        # of the node and the property name); `include`d into Walker.
        module ValueInference
          TYPE_BY_LITERAL = {
            Prism::StringNode => "string",
            Prism::InterpolatedStringNode => "string",
            Prism::SymbolNode => "string",
            Prism::IntegerNode => "number",
            Prism::FloatNode => "number",
            Prism::TrueNode => "boolean",
            Prism::FalseNode => "boolean",
            Prism::NilNode => "null"
          }.freeze

          NAME_HINT = {
            /_id\z|\Aid\z/ => "number",
            /_at\z|_on\z/ => "string",
            /_count\z|_total\z|\Atotal\z|\Apage\z/ => "number",
            /\Ais_|\A(has|can|should|was)_/ => "boolean"
          }.freeze

          COLLECTION_METHODS = %i[all where includes order limit offset group distinct none].freeze

          # Words that look plural but are conceptually singular, so e.g.
          # `json.earnings @summary, partial: ...` types `Earnings`, not
          # `Array<Earnings>`. Apps can extend this via Rails' inflector
          # uncountables (`singularize` consults inflections first), and a
          # `typelize:` pin always overrides the heuristic.
          SINGULAR_LOOKING_PLURALS = %w[news settings earnings analytics statistics series
            metadata data stats credentials].freeze

          BOOLEAN_GUARD_OPERATORS = %i[== != < > <= >= !].freeze
          private_constant :BOOLEAN_GUARD_OPERATORS

          # Jbuilder picks array-vs-object at runtime via `each`. Statically we
          # infer from the name (plural → array), falling back to known
          # collection method names on the argument.
          def looks_like_collection?(name, node)
            node = unwrap_parens(node)
            return true if node.is_a?(Prism::CallNode) && COLLECTION_METHODS.include?(node.name)
            plural_name?(name)
          end

          def plural_name?(name)
            str = name.to_s
            return false if str.empty?
            return false if SINGULAR_LOOKING_PLURALS.include?(str)
            str.singularize != str
          end

          # Value-level inference: the type, whether it came from a source-code
          # literal (`locked` — a same-named model column must not override
          # what the template demonstrably renders), and whether a conditional
          # arm contributes `null`.
          def infer_value(node, name:)
            node = unwrap_parens(node)
            return {type: "null", nullable: false, locked: true} if node.is_a?(Prism::NilNode)
            if TYPE_BY_LITERAL.key?(node.class)
              return {type: TYPE_BY_LITERAL[node.class], nullable: false, locked: true}
            end
            return {type: "string", nullable: false, locked: true} if time_call?(node)
            if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
              return infer_conditional_value(node, name: name)
            end
            # `a && b` renders b when a is truthy, null when a is nil, and the
            # literal `false` when a is false — so a boolean-valued left operand
            # leaks `false` into the value. Widen by `| null` always; also union
            # `boolean` in when the left is SYNTACTICALLY boolean (a predicate
            # `?`, a comparison, a `!`, a literal, or a boolean name hint). A
            # bare attribute (`@x.active`) gives no static boolean signal and is
            # treated as object-valued (nil-only leak), like `@obj && @obj.field`.
            if node.is_a?(Prism::AndNode)
              right = infer_value(node.right, name: name)
              type = boolean_guard?(node.left) ? union_with_boolean(right[:type]) : right[:type]
              return {type: type, nullable: true, locked: right[:locked]}
            end
            # `a || b` renders the FALLBACK when a is nil/false — nil never
            # survives the `||`, so the type comes from the right side and is
            # nullable only if that side is itself nilable (`@x.title || "Untitled"`
            # is `string`, not `string | null`).
            if node.is_a?(Prism::OrNode)
              right = infer_value(node.right, name: name)
              # A literal-nil fallback (`a || nil`) types from the left side's
              # name hint instead of emitting `null | null`.
              if right[:type] == "null"
                return {type: guess_from_name(name), nullable: true, locked: false}
              end
              return {type: right[:type], nullable: right[:nullable], locked: right[:locked]}
            end
            if node.is_a?(Prism::CallNode)
              if (signal = nil_signal_call(node, name: name))
                return signal
              end
              # Safe navigation ANYWHERE in the chain short-circuits to nil
              # (`a&.b.c` included), so the terminal value widens by `| null`;
              # the type hint comes from the terminal method name, then the
              # property name.
              if chain_safe_navigation?(node)
                return {type: name_hint(node.name) || guess_from_name(name), nullable: true, locked: false}
              end
            end
            {type: guess_from_name(name), nullable: false, locked: false}
          end

          # Explicit read-past-nil idioms on a call value: `x.try(:sym)` (nil
          # receiver or missing method → nil; hint from the tried name) and
          # `x.presence` (blank → nil; type from the receiver's own inference).
          def nil_signal_call(node, name:)
            case node.name
            when :try
              sym = positional_args(node).first
              if node.receiver && sym.is_a?(Prism::SymbolNode)
                return {type: name_hint(sym.unescaped) || guess_from_name(name), nullable: true, locked: false}
              end
            when :presence
              if node.receiver && node.arguments.nil? && node.block.nil?
                inner = infer_value(node.receiver, name: name)
                return {type: inner[:type], nullable: true, locked: inner[:locked]}
              end
            end
            nil
          end

          def chain_safe_navigation?(node)
            current = node
            while current.is_a?(Prism::CallNode)
              return true if current.safe_navigation?
              current = current.receiver
            end
            false
          end

          # A ternary / if-else expression as a VALUE: the runtime value is one
          # of the arms' final expressions. A `nil` arm (or a chain with no
          # else) contributes nullability; differing literal arm types union;
          # an uninferable arm falls back to name-hint/unknown for the type but
          # keeps the nullability signal.
          def infer_conditional_value(node, name:)
            branches, fully_covered = collect_branches(node)
            arms = branches.map { |body| body.last }
            if arms.any?(&:nil?)
              # An EMPTY branch body evaluates to nil at render, so a missing
              # arm contributes nullability — `json.total(if @f; else 5 end)`
              # renders null in the empty-arm state. (Found by the dead-code
              # audit: this arm returned nullable:false, a type lie.)
              return {type: guess_from_name(name), nullable: true, locked: false}
            end

            inferred = arms.map { |arm| infer_value(arm, name: name) }
            nullable = !fully_covered ||
              inferred.any? { |i| i[:type] == "null" || i[:nullable] }
            types = inferred.map { |i| i[:type] }.reject { |t| t == "null" }.uniq

            return {type: "null", nullable: false, locked: true} if types.empty?
            if types.any? { |t| self.class.unknown_type?(t) }
              return {type: guess_from_name(name), nullable: nullable, locked: false}
            end

            {
              type: (types.size == 1) ? types.first : types,
              nullable: nullable,
              locked: inferred.all? { |i| i[:locked] }
            }
          end

          def time_call?(node)
            node.is_a?(Prism::CallNode) &&
              node.receiver.is_a?(Prism::ConstantReadNode) &&
              node.receiver.name == :Time
          end

          # True when a `&&` left operand is syntactically boolean-valued (so its
          # `false` case leaks into the rendered value): a literal, a predicate
          # method (`admin?`), a comparison/negation operator, or a boolean name
          # hint (`is_active`). A bare attribute (`@x.active`) is undecidable
          # statically and treated as object-valued.
          def boolean_guard?(node)
            node = unwrap_parens(node)
            case node
            when Prism::TrueNode, Prism::FalseNode then true
            when Prism::CallNode
              BOOLEAN_GUARD_OPERATORS.include?(node.name) ||
                node.name.to_s.end_with?("?") ||
                name_hint(node.name.to_s) == "boolean"
            else false
            end
          end

          # Adds `boolean` to a rendered value type, deduped: a scalar becomes a
          # two-member union, a union gains the member, an already-boolean type
          # is unchanged.
          def union_with_boolean(type)
            members = Array(type)
            return type if members.include?("boolean")

            members += ["boolean"]
            (members.size == 1) ? members.first : members
          end

          def guess_from_name(name)
            name_hint(name) || "unknown"
          end

          def name_hint(name)
            NAME_HINT.each { |pat, t| return t if name.to_s.match?(pat) }
            nil
          end
        end
      end
    end
  end
end
