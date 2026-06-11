# frozen_string_literal: true

# Loaded lazily via `Typelizer::SerializerPlugins::Jbuilder.activate_walker!`
# — never as part of Typelizer's eager require chain. Everything that
# references `Prism::*` lives here so that requiring "typelizer" stays safe
# for users without the prism gem (or with only Ruby's bundled prism < 1.0).
module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Module-level cache so metadata extraction (eager, in `discover`)
        # and the full property walk (lazy, in `Plugin#properties`) share
        # one Prism parse per template.
        @parse_cache = {}
        class << self
          attr_reader :parse_cache

          def parsed_tree(path)
            parse_cache[path] ||= Prism.parse_file(path).value
          end

          # Reads top-level `typelize_as "Name"` and `typelize_from Model`
          # declarations without doing the full property walk. Used during
          # `discover` so the type name is fixed at registration time.
          def metadata_for(path)
            result = {type_name: nil, model: nil}
            return result unless File.exist?(path)

            tree = parsed_tree(path)
            tree.statements.body.each do |node|
              break unless node.is_a?(Prism::CallNode) && node.receiver.nil?
              arg = node.arguments&.arguments&.first
              case node.name
              when :typelize_as
                result[:type_name] ||= literal_string(arg)
              when :typelize_from
                result[:model] ||= literal_constant(arg)
              end
            end
            result
          rescue => e
            Typelizer.logger.warn("Typelizer::Jbuilder: failed to read metadata from #{path}: #{e.message}")
            {type_name: nil, model: nil}
          end

          def reset_cache!
            @parse_cache = {}
          end

          private

          def literal_string(node)
            case node
            when Prism::StringNode then node.unescaped
            when Prism::SymbolNode then node.unescaped
            end
          end

          def literal_constant(node)
            return nil unless node
            const_path = constant_path(node)
            const_path&.safe_constantize
          end

          def constant_path(node)
            case node
            when Prism::ConstantReadNode then node.name.to_s
            when Prism::ConstantPathNode
              [constant_path(node.parent), node.name.to_s].compact.join("::")
            end
          end
        end

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

        # Runtime mutations with no static type effect — skipped silently.
        # (`merge!` and `set!` are NOT here: they drop type information, so
        # they warn through the configured logger instead.)
        SKIP_CALLS = %i[null! nil! ignore_nil! key_format! deep_format_keys!].freeze

        PASSTHROUGH_CALLS = %i[cache! cache_if! cache_root!].freeze

        COLLECTION_METHODS = %i[all where includes order limit offset group distinct none].freeze

        # `column_inference: true` means the template is bound to a model the
        # model-plugin pipeline can type from (an AR class) — `extract!`-style
        # props are then emitted with `type: nil` so column inference fills
        # them in. Without it, name hints are applied directly (PORO/no-model
        # templates would otherwise be all-`unknown`).
        def initialize(path:, partial_resolver:, context:, column_inference: true)
          @path = path
          @partial_resolver = partial_resolver
          @context = context
          @column_inference = column_inference
        end

        def properties
          parsed.fetch(:properties)
        end

        def root_is_array
          parsed.fetch(:root_is_array)
        end

        # Names → parsed type info for every `typelize:` kwarg the walker
        # encountered. Surfaced to the plugin so it can install them as
        # serializer-class DSL attributes (suppressing AR column inference).
        def type_overrides
          parsed.fetch(:type_overrides)
        end

        private

        def parsed
          @parsed ||= begin
            @type_overrides = {}
            stmts = self.class.parsed_tree(@path).statements.body
            {
              root_is_array: detect_root_array(stmts),
              properties: extract(stmts, optional: false),
              type_overrides: @type_overrides
            }
          end
        end

        # Only top-level statements are inspected — documented v1 behavior.
        # A root `array!` (or collection `partial!`) nested under a
        # conditional cannot be expressed in the generated type, so the root
        # stays an object; we warn instead of silently mistyping.
        def detect_root_array(stmts)
          return true if stmts.any? { |n| root_array_call?(n) }

          warn_on_conditional_root_array(stmts)
          false
        end

        def root_array_call?(node)
          return false unless json_call?(node)

          (node.name == :array! && node.block) ||
            (node.name == :partial! && keyword_args(node).key?(:collection))
        end

        def warn_on_conditional_root_array(stmts)
          stmts.each do |node|
            next unless node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            branches, _ = collect_branches(node)
            branches.flatten.each do |n|
              next unless root_array_call?(n)
              log_warning(n, "a root array (`json.array!` / collection `json.partial!`) inside a conditional " \
                "is typed as an object — conditional root arrays are not supported; " \
                "use `typelize:` to pin the type")
            end
          end
        end

        def extract(stmts, optional:)
          stmts.flat_map { |n| extract_one(n, optional: optional) }.compact
        end

        def extract_one(node, optional:)
          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            return handle_conditional(node)
          end

          return unless json_call?(node)

          case node.name
          when :extract!, :call then handle_extract(node, optional: optional)
          when :partial! then handle_partial_bang(node)
          when :array! then handle_array_bang(node, optional: optional)
          when *PASSTHROUGH_CALLS then handle_passthrough(node, optional: optional)
          when :merge!
            warn_skipped(node, "`json.merge!` (dynamic merge)")
            []
          when :set!
            warn_skipped(node, "`json.set!` (dynamic key)")
            []
          when *SKIP_CALLS then []
          else handle_prop(node, optional: optional)
          end
        end

        def handle_prop(node, optional:)
          name = node.name.to_s
          args = positional_args(node)
          kwargs = keyword_args(node)
          optional ||= inertia_marks_optional?(kwargs[:inertia])

          return property_from_override(name, kwargs[:typelize], optional: optional) if kwargs[:typelize]

          if node.block
            return handle_prop_with_block(node, name: name, optional: optional)
          end

          if (partial = kwargs[:partial])
            return prop_from_partial(name, args, partial, optional: optional)
          end

          if (collection_props = collection_attr_shortcut(args))
            return build_property(name, type: Shape.new(properties: collection_props), optional: optional, multi: true)
          end

          if (first = args.first)
            inferred = infer_type(first, name: name)
            return build_property(name, type: inferred, optional: optional, nullable: inferred == "null")
          end

          build_property(name, type: "unknown", optional: optional)
        end

        # Routes `typelize:` overrides through TypeParser so shortcuts
        # (`string?`, `number[]`, `string?[]`) expand into real TS. The
        # `dsl_attrs` carry only what the user explicitly asserted in the
        # typelize string — structural optionality (from `if` blocks, inertia
        # kwargs) belongs on the property itself so `merge_branches` and
        # similar context-aware passes can still adjust it without being
        # overwritten by the registered DSL entry.
        def property_from_override(name, override, optional:)
          parsed = TypeParser.parse_declaration(override)
          dsl_attrs = {
            type: parsed[:type] || override.to_s,
            nullable: parsed[:nullable] || false,
            multi: parsed[:multi] || false
          }
          dsl_attrs[:optional] = true if parsed[:optional]
          @type_overrides[name] = dsl_attrs if @type_overrides
          build_property(name, **dsl_attrs, optional: optional || parsed[:optional] || false)
        end

        # If the block body is purely `json.partial!` calls, emit each as an
        # imported interface and intersect them — this is how jbuilder fakes
        # Alba's named-trait composition (`Course & CourseDetails`). Falls
        # back to an inline `Shape` for any other body so AR model inference
        # (column types, enums) keeps working inside nested blocks via
        # `infer_nested_property_types`.
        def handle_prop_with_block(node, name:, optional:)
          multi = !node.block.parameters.nil?
          if (interfaces = composed_partials(node.block))
            base, *additional = interfaces
            return build_property(name, type: base, additional_types: additional, optional: optional, multi: multi)
          end
          build_property(name, type: Shape.new(properties: shape_body(node.block)), optional: optional, multi: multi)
        end

        # Returns the resolved Interfaces for a block whose body is purely
        # `json.partial!` calls, or `nil` if the body contains anything else
        # (so the caller can fall back to inline-shape extraction).
        def composed_partials(block_node)
          stmts = block_node.body&.body || []
          return nil if stmts.empty?
          interfaces = []
          stmts.each do |stmt|
            return nil unless json_call?(stmt) && stmt.name == :partial!
            first = positional_args(stmt).first
            return nil unless first.is_a?(Prism::StringNode)
            partial_class = @partial_resolver.call(first.unescaped)
            return nil unless partial_class
            interfaces << @context.interface_for(partial_class)
          end
          interfaces
        end

        def collection_attr_shortcut(args)
          return nil if args.size < 2
          first = args.first
          return nil unless first.is_a?(Prism::InstanceVariableReadNode) || first.is_a?(Prism::CallNode)
          props = symbol_args_to_properties(args)
          props.empty? ? nil : props
        end

        def prop_from_partial(name, args, partial, optional:)
          partial_class = @partial_resolver.call(partial)
          return build_property(name, type: "unknown", optional: optional) unless partial_class

          iface = @context.interface_for(partial_class)
          build_property(name, type: iface, optional: optional, multi: looks_like_collection?(name, args.first))
        end

        # Jbuilder resolves array-vs-object at runtime by checking if the value
        # responds to `each`. Statically, we infer from the property name
        # (plural → array) and fall back to known collection method names on the
        # argument.
        def looks_like_collection?(name, node)
          return true if node.is_a?(Prism::CallNode) && COLLECTION_METHODS.include?(node.name)
          plural_name?(name)
        end

        # Words that LOOK plural (`singularize` finds a different form) but
        # are conceptually singular nouns. Treated as singular by the
        # collection heuristic so `json.earnings @summary, partial: ...`
        # generates `earnings: Earnings`, not `Array<Earnings>`. Apps with
        # additional domain-specific cases can extend Rails' inflector via
        # `Inflector.inflections { |i| i.uncountable %w[...] }` — that's
        # also honored because `singularize` consults inflections first.
        SINGULAR_LOOKING_PLURALS = %w[news settings earnings analytics statistics series].freeze

        def plural_name?(name)
          str = name.to_s
          return false if str.empty?
          return false if SINGULAR_LOOKING_PLURALS.include?(str)
          str.singularize != str
        end

        # Handles both the positional form (`json.partial! "posts/post"`) and
        # the kwargs-only form (`json.partial! partial: "posts/post",
        # collection: @posts, as: :post`). At the template root a collection
        # partial becomes the root array (see `detect_root_array`); inside a
        # block it cannot be expressed (the partial's properties merge into
        # the surrounding shape), so we warn instead of silently mistyping.
        def handle_partial_bang(node)
          first = positional_args(node).first
          kwargs = keyword_args(node)

          partial_name =
            if first.is_a?(Prism::StringNode)
              first.unescaped
            elsif kwargs[:partial].is_a?(String)
              kwargs[:partial]
            end

          unless partial_name
            warn_skipped(node, "`json.partial!` with a dynamic template reference")
            return []
          end

          if @nested && kwargs.key?(:collection)
            log_warning(node, "`json.partial!` with `collection:` inside a block is typed as a merged object, " \
              "not an array — use `json.<name> @collection, partial: \"...\", as: ...` or `typelize:`")
          end

          partial_class = @partial_resolver.call(partial_name)
          unless partial_class
            warn_skipped(node, "`json.partial! \"#{partial_name}\"` (template could not be resolved)")
            return []
          end

          @context.interface_for(partial_class).properties
        end

        def handle_extract(node, optional:)
          symbol_args_to_properties(positional_args(node), optional: optional)
        end

        def symbol_args_to_properties(args, optional: false)
          args.drop(1)
            .select { |a| a.is_a?(Prism::SymbolNode) }
            .map { |sym| property_from_column(sym.unescaped, optional: optional) }
        end

        # `json.array! @items do |item| ... end` — emit the element shape;
        # the root-array wrapping itself is handled via `root_is_array`.
        # Blockless forms can't participate in the root-array detection
        # (documented v1 limitation), so they warn instead of silently
        # producing an object type for an array value.
        def handle_array_bang(node, optional:)
          if node.block
            shape_body(node.block)
          elsif (args = positional_args(node)).size >= 2
            log_warning(node, "`json.array!` without a block emits its attributes as an object shape, " \
              "not an array — use the block form or `typelize:` to pin an array type")
            collection_attr_shortcut(args) || []
          else
            warn_skipped(node, "`json.array!` without a block or attribute list")
            []
          end
        end

        def handle_passthrough(node, optional:)
          return [] unless node.block
          extract(node.block.body&.body || [], optional: optional)
        end

        # Walks an if/elsif/else (or unless/else) chain and merges same-name
        # properties across branches. A property emitted in every branch of a
        # fully-covered chain (terminating in `else`) stays required; anything
        # else is optional.
        def handle_conditional(node)
          branches, fully_covered = collect_branches(node)
          branch_props = branches.map { |body| extract(body, optional: false) }
          merge_branches(branch_props, fully_covered: fully_covered)
        end

        def collect_branches(node)
          # `unless` has no elsif chain — only an optional `else_clause`
          # (which, by unless-semantics, is the condition-true branch; the
          # branches are symmetric for merging purposes). Prism exposes it as
          # `else_clause`, not `subsequent`.
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

        # When the same property name appears in multiple branches we widen
        # nullability across them (`Foo` + `Foo | null` → `Foo | null`) and
        # widen optionality: a prop is optional unless every branch of a
        # fully-covered chain emits it, and stays optional if any branch
        # marked it optional (e.g. via `inertia: :defer`). Type ambiguity
        # (different base types per branch) is not unioned — first branch
        # wins; flag with `typelize:` if needed.
        def merge_branches(branch_props, fully_covered:)
          names = branch_props.flat_map { |props| props.map(&:name) }.uniq
          names.map do |name|
            occurrences = branch_props.map { |props| props.find { |p| p.name == name } }
            present = occurrences.compact
            base = present.first
            nullable = present.any?(&:nullable)
            optional = present.any?(&:optional) || !(fully_covered && occurrences.all?)
            base.with(optional: optional, nullable: nullable)
          end
        end

        # With an inferable (AR) model the type stays nil so model inference
        # resolves it from `_typelizer_model_name` — nested shapes only run
        # inference on nil-typed props, so a premature hint would block the
        # column type. Without one (PORO `typelize_from`, no model), name
        # hints are the best signal available.
        def property_from_column(col, optional: false)
          build_property(col, type: @column_inference ? nil : name_hint(col), optional: optional)
        end

        def build_property(name, type: nil, optional: false, nullable: false, multi: false, additional_types: nil)
          Property.new(
            name: name,
            type: type,
            optional: optional,
            nullable: nullable,
            multi: multi,
            column_name: name,
            additional_types: additional_types
          )
        end

        def shape_body(block_node)
          with_nested { extract(block_node.body&.body || [], optional: false) }
        end

        def with_nested
          prev = @nested
          @nested = true
          yield
        ensure
          @nested = prev
        end

        def warn_skipped(node, construct)
          log_warning(node, "#{construct} cannot be statically typed; no property emitted — " \
            "use `typelize:` to pin a type")
        end

        def log_warning(node, message)
          Typelizer.logger.warn("Typelizer::Jbuilder: #{@path}:#{node.location.start_line}: #{message}")
        end

        def inertia_marks_optional?(inertia)
          case inertia
          when :defer, :optional then true
          when Hash then inertia.key?(:defer) || inertia.key?(:optional)
          else false
          end
        end

        def infer_type(node, name:)
          return "null" if node.is_a?(Prism::NilNode)
          return TYPE_BY_LITERAL[node.class] if TYPE_BY_LITERAL.key?(node.class)
          return "string" if time_call?(node)
          guess_from_name(name)
        end

        def time_call?(node)
          node.is_a?(Prism::CallNode) &&
            node.receiver.is_a?(Prism::ConstantReadNode) &&
            node.receiver.name == :Time
        end

        def guess_from_name(name)
          name_hint(name) || "unknown"
        end

        def name_hint(name)
          NAME_HINT.each { |pat, t| return t if name.to_s.match?(pat) }
          nil
        end

        def json_call?(node)
          node.is_a?(Prism::CallNode) &&
            node.receiver.is_a?(Prism::CallNode) &&
            node.receiver.name == :json &&
            node.receiver.receiver.nil?
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
          when Prism::HashNode then assoc_pairs(node.elements)
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
