# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Static recognition of Inertia prop directives in templates — the
        # kwarg form (`json.stats @stats, inertia: :defer`) and the
        # resolver-object form (`json.stats JbuilderInertia.defer { ... }`).
        # Stateless tables plus their lookup methods; `include`d into Walker.
        module InertiaDirectives
          # Internal widening registries. Table-driven (a second adapter is one
          # entry away) but module-private — no registration API until one
          # exists. The vocabulary mirrors jbuilder-inertia's
          # `PropBuilder::KNOWN_DIRECTIVES`; only `defer`/`optional` can omit a
          # key from the initial Inertia load, so only they widen to optional.
          INERTIA_WIDENING_DIRECTIVES = %i[defer optional].freeze
          private_constant :INERTIA_WIDENING_DIRECTIVES

          # kwarg → lambda deciding optionality from its literal value, across
          # the symbol (`inertia: :defer`), array, and hash
          # (`inertia: {defer: {...}}`) forms. Non-widening directives and
          # unrecognized shapes never widen.
          OPTIONAL_KWARG_RESOLVERS = {
            inertia: lambda do |value|
              case value
              when Symbol then INERTIA_WIDENING_DIRECTIVES.include?(value)
              when Array then value.any? { |v| v.is_a?(Symbol) && INERTIA_WIDENING_DIRECTIVES.include?(v) }
              when Hash then INERTIA_WIDENING_DIRECTIVES.any? { |directive| value.key?(directive) }
              else false
              end
            end
          }.freeze
          private_constant :OPTIONAL_KWARG_RESOLVERS

          # Resolver-object form: `json.stats JbuilderInertia.defer { ... }`.
          # Namespace constant name → known constructor methods plus the subset
          # that widens. Matched purely syntactically — typelizer never loads
          # the jbuilder-inertia gem.
          VALUE_NODE_RESOLVERS = {
            "JbuilderInertia" => {
              methods: %i[defer optional merge deep_merge once always scroll].freeze,
              widening: INERTIA_WIDENING_DIRECTIVES
            }.freeze
          }.freeze
          private_constant :VALUE_NODE_RESOLVERS

          def value_node_resolver(node)
            return nil unless node.is_a?(Prism::CallNode)

            namespace = resolver_namespace(node.receiver)
            entry = namespace && VALUE_NODE_RESOLVERS[namespace]
            (entry && entry[:methods].include?(node.name)) ? entry : nil
          end

          # Matches the top-level namespace constant in both spellings:
          # `JbuilderInertia.defer` (ConstantReadNode) and
          # `::JbuilderInertia.defer` (ConstantPathNode with no parent).
          def resolver_namespace(receiver)
            case receiver
            when Prism::ConstantReadNode then receiver.name.to_s
            when Prism::ConstantPathNode then receiver.parent.nil? ? receiver.name.to_s : nil
            end
          end

          # The final expression of the resolver's block, if any — the value
          # the resolver will produce at runtime. Block-argument forms
          # (`JbuilderInertia.defer(&blk)`) carry no statically visible body.
          def resolver_value_expression(node)
            block = node.block
            block.body&.body&.last if block.is_a?(Prism::BlockNode)
          end
        end
      end
    end
  end
end
