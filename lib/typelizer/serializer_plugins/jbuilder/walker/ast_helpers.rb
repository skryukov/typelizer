# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Prism AST plumbing shared across the walk: argument splitting,
        # literal extraction, paren unwrapping, and conditional-chain
        # collection. Stateless except `contains_json_call?`, which resolves
        # `json_call?` on the host (builder aliases are walk state). Both
        # `include`d (the instance walk) and `extend`ed (class-level
        # `metadata_for`) into Walker.
        module AstHelpers
          # A value spelled with a space before its parens (`json.x (expr)`)
          # parses as a ParenthesesNode argument — unwrap single-statement
          # bodies so the inner expression infers exactly like the tight
          # spelling `json.x(expr)`.
          def unwrap_parens(node)
            while node.is_a?(Prism::ParenthesesNode)
              stmts = node.body.is_a?(Prism::StatementsNode) ? node.body.body : nil
              break unless stmts&.size == 1
              node = stmts.first
            end
            node
          end

          def collect_branches(node)
            # `unless` has no elsif chain — only an optional `else_clause` (Prism
            # exposes it as `else_clause`, not `subsequent`); branches are
            # symmetric for merging.
            if node.is_a?(Prism::UnlessNode)
              branches = [node.statements&.body || []]
              if (else_clause = node.else_clause)
                branches << (else_clause.statements&.body || [])
                return [branches, true]
              end
              return [branches, false]
            end

            branches = [node.statements&.body || []]
            current = node
            while (sub = current.subsequent)
              case sub
              when Prism::ElseNode
                branches << (sub.statements&.body || [])
                return [branches, true]
              when Prism::IfNode
                branches << (sub.statements&.body || [])
                current = sub
              else
                break
              end
            end
            [branches, false]
          end

          def contains_json_call?(node)
            return true if json_call?(node)
            node.compact_child_nodes.any? { |child| contains_json_call?(child) }
          end

          def positional_args(node)
            (node.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          end

          def keyword_args(node)
            kw = (node.arguments&.arguments || []).find { |a| a.is_a?(Prism::KeywordHashNode) }
            kw ? assoc_pairs(kw.elements) : {}
          end

          def literal_value(node)
            case node
            when Prism::StringNode then node.unescaped
            when Prism::SymbolNode then node.unescaped.to_sym
            when Prism::IntegerNode, Prism::FloatNode then node.value
            when Prism::TrueNode then true
            when Prism::FalseNode then false
            when Prism::ArrayNode then node.elements.map { |el| literal_value(el) }
            when Prism::HashNode then assoc_pairs(node.elements)
            when Prism::ParenthesesNode
              unwrapped = unwrap_parens(node)
              unwrapped.equal?(node) ? node : literal_value(unwrapped)
            else node
            end
          end

          def assoc_pairs(elements)
            elements.each_with_object({}) do |el, h|
              next unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
              h[el.key.unescaped.to_sym] = literal_value(el.value)
            end
          end
        end
      end
    end
  end
end
