# frozen_string_literal: true

require "digest"
require "set"

# Loaded lazily via `Jbuilder.activate_walker!`, never on the eager require
# chain: all `Prism::*` references live here so `require "typelizer"` stays
# safe without the prism gem (or with Ruby's bundled prism < 1.0).
module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # Shared Prism parse per template (eager metadata extraction + lazy
        # property walk).
        @parse_cache = {}
        # Per-cycle warning dedup keyed by [path, prop, line] — each writer
        # re-walks a template within one cycle, but the warning fires once.
        @warned_unknowns = Set.new
        # Templates whose walk is on the stack — breaks cyclic `json.partial!`
        # merges (A merges B merges A); see `handle_partial_bang`.
        @walks_in_progress = Set.new
        # Per-cycle dedup for empty-partial warnings, keyed by
        # [path, line, partial name]. Same rationale as `@warned_unknowns`.
        @warned_empty_partials = Set.new
        class << self
          attr_reader :parse_cache, :warned_unknowns, :walks_in_progress, :warned_empty_partials

          # Digest-keyed parse cache. Within a cycle reuse is safe
          # (`reset_cache!` clears it); across cycles the digest
          # auto-invalidates an edited template, so long-lived processes never
          # serve a stale parse. The source is read once, then digested and
          # parsed from that one string (no read/parse race); an unreadable
          # template raises a named `Typelizer::Error` (`metadata_for`
          # swallows it, the property walk re-raises).
          def parsed_tree(path)
            content = begin
              File.read(path)
            rescue SystemCallError => e
              raise Typelizer::Error,
                "Typelizer::Jbuilder: could not read template #{path} (#{e.class}: #{e.message})"
            end

            digest = Digest::SHA256.hexdigest(content)
            entry = parse_cache[path]
            return entry[:tree] if entry && entry[:digest] == digest

            tree = Prism.parse(content).value
            parse_cache[path] = {digest: digest, tree: tree}
            tree
          end

          # The single source of truth for "the walker couldn't type this":
          # nil (delegated to model inference) or a hard "unknown". Shared by
          # the walk-time candidate recording here and the plugin's
          # post-inference warning decision.
          def unknown_type?(type)
            type.nil? || ((type.is_a?(String) || type.is_a?(Symbol)) && type.to_s == "unknown")
          end

          # Reads top-level `typelize_as "Name"` and `typelize_from Model`
          # declarations without doing the full property walk. Used during
          # `discover` so the type name is fixed at registration time.
          # `:model` is the constant's NAME — resolution happens lazily at
          # generation time (see `Typelizer::Jbuilder.template`).
          def metadata_for(path)
            result = {type_name: nil, model: nil}
            return result unless File.exist?(path)

            tree = parsed_tree(path)
            tree.statements.body.each do |node|
              # Scan every top-level bare call, not just the leading run: a
              # `typelize_as`/`typelize_from` after a `json.*` line (which has a
              # receiver) must still be picked up rather than silently dropped.
              next unless node.is_a?(Prism::CallNode) && node.receiver.nil?
              arg = node.arguments&.arguments&.first
              case node.name
              when :typelize_as
                result[:type_name] ||= literal_string(arg)
              when :typelize_from
                result[:model] ||= constant_path(arg)
              end
            end
            result
          rescue => e
            Typelizer.logger.warn("Typelizer::Jbuilder: failed to read metadata from #{path}: #{e.message}")
            {type_name: nil, model: nil}
          end

          def reset_cache!
            @parse_cache = {}
            @warned_unknowns = Set.new
            @walks_in_progress = Set.new
            @warned_empty_partials = Set.new
          end

          private

          def literal_string(node)
            case node
            when Prism::StringNode then node.unescaped
            when Prism::SymbolNode then node.unescaped
            end
          end

          def constant_path(node)
            return nil unless node
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

        # Every type-distorting jbuilder API method warns through the logger
        # rather than being skipped silently (see the `extract_one` dispatch);
        # jbuilder_api_canary_spec guards that the dispatch stays exhaustive.
        PASSTHROUGH_CALLS = %i[cache! cache_if! cache_root!].freeze

        COLLECTION_METHODS = %i[all where includes order limit offset group distinct none].freeze

        # `column_inference: true` → bound to a model: `extract!`-style props
        # are emitted with `type: nil` so column inference fills them in.
        # Otherwise name hints apply directly (a PORO/no-model template would
        # otherwise be all-`unknown`).
        def initialize(path:, partial_resolver:, context:, column_inference: true)
          @path = path
          @partial_resolver = partial_resolver
          @context = context
          @column_inference = column_inference
          @unknown_lines = {}
          # Prop names that fell back to `unknown` but already warned at walk
          # time with a more specific message (an empty `partial:` reference,
          # a value-less `typelize:`), so the generic post-inference unknown
          # warning is suppressed for them.
          @prewarned_props = Set.new
        end

        def properties
          parsed.fetch(:properties)
        end

        def root_is_array
          parsed.fetch(:root_is_array)
        end

        # See `detect_root_array_element`: the partial's Interface, the
        # string "unknown", or nil when the root array (if any) inlines its
        # element shape.
        def root_array_element
          parsed.fetch(:root_array_element)
        end

        # prop name → source line for properties whose walker-side type is
        # nil or "unknown". These are CANDIDATE unknowns: model inference
        # runs after the walk (`Interface#infer_types`) and can still rescue
        # them, so the actual warning decision is made post-inference by
        # `Plugin#after_type_inference` — this map only supplies the
        # file:line the walker alone knows.
        def unknown_candidates
          parsed.fetch(:unknown_lines)
        end

        private

        def parsed
          @parsed ||= begin
            self.class.walks_in_progress.add(@path)
            begin
              stmts = self.class.parsed_tree(@path).statements.body
              root_is_array = detect_root_array(stmts)
              {
                root_is_array: root_is_array,
                root_array_element: root_is_array ? detect_root_array_element(stmts) : nil,
                properties: extract(stmts, optional: false),
                # Populated as a side effect of `extract` above (see
                # `note_unknown_candidate`); captured here so `unknown_candidates`
                # reads it through `parsed` like every other derived value.
                unknown_lines: @unknown_lines
              }
            ensure
              self.class.walks_in_progress.delete(@path)
            end
          end
        end

        # Only top-level statements are inspected (v1). A root `array!` /
        # collection `partial!` under a conditional can't be expressed, so the
        # root stays an object and we warn instead of mistyping.
        def detect_root_array(stmts)
          return true if stmts.any? { |n| root_array_call?(n) }

          warn_on_conditional_root_array(stmts)
          false
        end

        def root_array_call?(node)
          return false unless json_call?(node)

          (node.name == :array! && (node.block || keyword_args(node)[:partial].is_a?(String))) ||
            (node.name == :partial! && keyword_args(node).key?(:collection))
        end

        # Blockless `json.array! @xs, partial: "xs/x"` at the root: the element
        # type is the partial's named interface, rendering
        # `type X = Array<Element>;`. Unresolvable or empty partials warn and
        # fall back to `Array<unknown>` (naming an empty interface would emit a
        # dangling TS2305 import).
        def detect_root_array_element(stmts)
          node = stmts.find { |n| root_array_partial_call?(n) }
          return nil unless node

          partial_name = keyword_args(node)[:partial]
          partial_class = @partial_resolver.call(partial_name)
          unless partial_class
            warn_skipped(node, "`json.array!` with partial \"#{partial_name}\" (template could not be resolved)")
            return "unknown"
          end

          iface = @context.interface_for(partial_class)
          if empty_partial_interface?(partial_class, iface)
            warn_empty_partial(node, partial_name, "the root array element falls back to `unknown`")
            return "unknown"
          end
          iface
        end

        def root_array_partial_call?(node)
          json_call?(node) && node.name == :array! && node.block.nil? &&
            keyword_args(node)[:partial].is_a?(String)
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
          merge_same_level(stmts.flat_map { |n| extract_one(n, optional: optional) }.compact)
        end

        # Collapses same-name properties emitted at one level (an
        # unconditional `json.foo` plus a conditional re-emit, or an own prop
        # alongside a merged partial's) into one TS key. Same widening as
        # `merge_branches`: required if any occurrence is unconditional,
        # nullability widens, type is first-non-null-wins unless
        # `typelize:`-asserted (a bare `nil` contributes nullability, not type).
        def merge_same_level(props)
          return props if props.map { |p| p.name.to_s }.uniq.size == props.size

          props.group_by { |p| p.name.to_s }.values.map do |occurrences|
            next occurrences.first if occurrences.size == 1

            base = occurrences.find(&:user_asserted) ||
              occurrences.find { |p| !null_type?(p) } || occurrences.first
            base.with(
              optional: occurrences.all?(&:optional),
              nullable: widened_nullable(base, occurrences)
            )
          end
        end

        # Control-flow forms the walker doesn't model: bodies aren't walked
        # (v1), so json.* calls inside warn instead of being dropped silently.
        UNWALKED_CONTROL_FLOW = {
          Prism::CaseNode => "case",
          Prism::CaseMatchNode => "case",
          Prism::WhileNode => "while",
          Prism::UntilNode => "until"
        }.freeze
        private_constant :UNWALKED_CONTROL_FLOW

        def extract_one(node, optional:)
          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            return handle_conditional(node)
          end

          if (keyword = UNWALKED_CONTROL_FLOW[node.class])
            warn_skipped(node, "a `#{keyword}` body containing json properties") if contains_json_call?(node)
            return []
          end

          unless json_call?(node)
            # A non-json statement wrapping the DSL (iteration, any expression)
            # is never walked, so json calls inside it would drop silently —
            # warn. Plain non-json statements (assignments, helpers) stay silent.
            warn_skipped(node, "iteration or expression wrapping json properties") if contains_json_call?(node)
            return []
          end

          case node.name
          when :extract!, :call then handle_extract(node, optional: optional)
          when :partial! then handle_partial_bang(node)
          when :array! then handle_array_bang(node, optional: optional)
          when *PASSTHROUGH_CALLS then handle_passthrough(node, optional: optional)
          when :merge!
            warn_skipped(node, "`json.merge!` (dynamic merge)")
            []
          when :set! then handle_set_bang(node, optional: optional)
          when :child!
            # Only typeable as an element of an enclosing `json.<name> do ... end`
            # array (handled in `handle_prop_with_block`); reaching here means
            # there's no property to attach it to.
            warn_skipped(node, "`json.child!` at the template root (no enclosing `json.<name>` block)")
            []
          when :cache_collection!
            # Both forms (bare and `partial:`) render each collection member
            # through fragment-cache plumbing the walker cannot follow.
            warn_skipped(node, "`json.cache_collection!` (runtime collection caching)")
            []
          when :key_format!
            log_warning(node, "`json.key_format!` changes runtime key casing; generated types use " \
              "source names — align casing via Typelizer's `properties_transformer` config")
            []
          when :ignore_nil!
            log_warning(node, "`json.ignore_nil!` omits nil-valued keys at runtime; " \
              "consider marking affected properties optional via `typelize:`")
            []
          when :deep_format_keys!
            log_warning(node, "`json.deep_format_keys!` changes runtime key casing of nested " \
              "structures; generated types use source names — align casing via Typelizer's " \
              "`properties_transformer` config")
            []
          when :nil!, :null!
            log_warning(node, "`json.#{node.name}` renders `null` at runtime; the generated " \
              "type does not reflect this — pin the shape with `typelize:` if it matters")
            []
          when :attributes!, :target!
            log_warning(node, "`json.#{node.name}` is a jbuilder internal accessor, not a " \
              "JSON key; no property emitted")
            []
          else note_unknown_candidate(node, handle_prop(node, optional: optional))
          end
        end

        # Records the source line of a property the walker couldn't type (nil
        # → model inference, or a hard "unknown"). No warning here: a bound
        # model's columns can still fill it in post-walk, so warning now would
        # cry wolf.
        def note_unknown_candidate(node, prop)
          return prop unless prop.is_a?(Property)

          if !prop.user_asserted && self.class.unknown_type?(prop.type) &&
              !@prewarned_props.include?(prop.name.to_s)
            @unknown_lines[prop.name.to_s] ||= node.location.start_line
          end
          prop
        end

        # `name:`/`args:` overrides let `json.set!` with a literal key reuse
        # this path — it's `json.<key> ...` spelled differently: name from the
        # first arg, remaining args behave like a normal prop's.
        def handle_prop(node, optional:, name: node.name.to_s, args: positional_args(node))
          kwargs = keyword_args(node)
          optional ||= kwargs.any? { |key, value| OPTIONAL_KWARG_RESOLVERS[key]&.call(value) }

          value = args.first
          if (resolver = value_node_resolver(value))
            optional ||= resolver[:widening].include?(value.name)
            # The resolver block is arbitrary Ruby returning a plain value
            # (never DSL), so it isn't walked as a shape; its final expression
            # feeds the normal inference path below.
            value = resolver_value_expression(value)
          end

          if (override = kwargs[:typelize])
            if literal_override?(override)
              if args.any? || node.block
                return property_from_override(name, override, optional: optional)
              end
              # No value and no block: at render time the braceless kwargs
              # hash IS the value (see SetExt's sole-hash rule), rendered as a
              # nested object — honoring the assertion would type a shape
              # that never renders.
              log_warning(node, "`typelize:` without a value or block is rendered as the " \
                "property's literal hash value, not honored as an annotation — " \
                "add a value or block (e.g. `json.#{name} @#{name}, typelize: #{override.to_s.inspect}`)")
              @prewarned_props << name.to_s
              return build_property(name, type: "unknown", optional: optional)
            end
            # A non-literal `typelize:` (constant, variable, method call)
            # cannot be honored statically — fall through to normal
            # inference instead of stringifying a Prism node.
            log_warning(node, "`typelize:` with a non-literal value cannot be honored; " \
              "falling back to type inference — use a literal type (e.g. `typelize: \"string\"`)")
          end

          if node.block.is_a?(Prism::BlockNode)
            return handle_prop_with_block(node, name: name, optional: optional, args: args)
          end

          if (partial = kwargs[:partial])
            if partial.is_a?(String)
              return prop_from_partial(node, name, args, partial, optional: optional)
            end
            # Mirrors `handle_partial_bang`: a dynamic template reference
            # can't be resolved statically, so the property itself survives
            # as `unknown` (or a name hint) instead of crashing the walk.
            log_warning(node, "`partial:` with a dynamic template reference cannot be resolved " \
              "statically — the property falls back to name-hint/`unknown` typing; " \
              "use `typelize:` to pin a type")
            return build_property(name, type: guess_from_name(name), optional: optional)
          end

          if (collection_props = collection_attr_shortcut(args))
            # Array-vs-object follows the same runtime heuristic as the partial
            # form (`prop_from_partial`): jbuilder emits an array only when the
            # value is a collection, so a singular name stays an object.
            multi = looks_like_collection?(name, args.first)
            return build_property(name, type: Shape.new(properties: collection_props), optional: optional, multi: multi)
          end

          if value
            return build_property(name, type: infer_type(value, name: name), optional: optional)
          end

          if resolver
            # Resolver with no inferable block expression: keep the name-hint
            # signal instead of a hard "unknown".
            return build_property(name, type: guess_from_name(name), optional: optional)
          end

          build_property(name, type: "unknown", optional: optional)
        end

        # `json.set!` with a literal String/Symbol key routes through the
        # normal property flow under that key; `Property#render` quotes keys
        # that aren't valid identifiers. Dynamic keys warn.
        def handle_set_bang(node, optional:)
          args = positional_args(node)
          key = args.first
          unless key.is_a?(Prism::StringNode) || key.is_a?(Prism::SymbolNode)
            warn_skipped(node, "`json.set!` (dynamic key)")
            return []
          end

          note_unknown_candidate(node, handle_prop(node, optional: optional, name: key.unescaped, args: args.drop(1)))
        end

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

        # `typelize:` is honored only for a literal type *string* — the
        # documented form, e.g. `typelize: "{ id: number }"` (a Symbol is
        # accepted as a bare type name). A Ruby hash/array value can't be
        # turned into a TS type by TypeParser, so it falls through to the
        # non-literal warning instead of stringifying into a broken type.
        def literal_override?(value)
          value.is_a?(String) || value.is_a?(Symbol)
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

        # Composed-partial blocks emit named intersections — jbuilder's
        # stand-in for Alba's named-trait composition:
        #
        #   json.course do                       course: Course & CourseDetails
        #     json.partial! "courses/course"
        #     json.partial! "courses/course_details"
        #   end
        #
        # Each top-level resolvable string `json.partial!` becomes a named
        # interface; anything else (own props, conditionals, dynamic partials)
        # trails the intersection as an inline `Shape`. A block with no
        # nameable partials stays a plain `Shape` so nested model inference
        # keeps working (`infer_nested_property_types`).
        def handle_prop_with_block(node, name:, optional:, args: positional_args(node))
          # jbuilder renders an array iff a positional collection VALUE
          # accompanies the block (`json.foo @xs do ... end`), regardless of
          # whether the block declares a parameter — see jbuilder's `_set`.
          # `args` excludes the key for `json.set! "k", value do ... end`.
          multi = args.any?
          # An object block (no value) is yielded the builder itself, so a
          # `do |json| ... end` param rebinds it to a local; register that alias
          # so the body's `<param>.x` calls are recognized. Array blocks are
          # yielded the element instead — no alias.
          with_json_alias(multi ? nil : block_builder_alias(node.block)) do
            children, non_children = partition_child_bangs(node.block)
            if children.any?
              next handle_child_array(node, name: name, optional: optional, children: children, rest: non_children)
            end

            interfaces, rest = partition_composed_partials(node.block, prop_name: name)
            if interfaces.any?
              additional = interfaces.drop(1)
              rest_props = with_nested { extract(rest, optional: false) }
              additional += [Shape.new(properties: rest_props)] if rest_props.any?
              next build_property(name, type: interfaces.first, additional_types: additional, optional: optional, multi: multi)
            end
            build_property(name, type: Shape.new(properties: shape_body(node.block)), optional: optional, multi: multi)
          end
        end

        # Splits a block body into [`json.child!` calls, other stmts].
        def partition_child_bangs(block_node)
          (block_node.body&.body || []).partition { |stmt| json_call?(stmt) && stmt.name == :child! }
        end

        # `json.<name> do ... json.child! ... end` is jbuilder's literal-array
        # form: the property becomes an array whose element type merges every
        # child's shape with full-coverage `merge_branches` semantics. Named
        # props mixed into the same block can't be expressed on one TS key, so
        # they're dropped with a warning and only the elements are typed.
        def handle_child_array(node, name:, optional:, children:, rest:)
          if rest.any?
            log_warning(node, "mixing `json.child!` with named properties is not statically typeable; " \
              "typing the array elements only — use `typelize:` to pin the full type")
          end

          branch_props = children.map do |child|
            child.block.is_a?(Prism::BlockNode) ? shape_body(child.block) : []
          end
          merged = merge_branches(branch_props, fully_covered: true)
          build_property(name, type: Shape.new(properties: merged), optional: optional, multi: true)
        end

        # Splits a block into [named partial interfaces, other stmts]. Only a
        # top-level string-literal `json.partial!` with no `collection:` and a
        # resolvable template counts as a named member; everything else stays.
        def partition_composed_partials(block_node, prop_name:)
          interfaces = []
          rest = []
          (block_node.body&.body || []).each do |stmt|
            if (iface = nameable_partial_interface(stmt, prop_name: prop_name))
              interfaces << iface
            else
              rest << stmt
            end
          end
          [interfaces.uniq, rest]
        end

        def nameable_partial_interface(stmt, prop_name:)
          return nil unless json_call?(stmt) && stmt.name == :partial!
          first = positional_args(stmt).first
          return nil unless first.is_a?(Prism::StringNode)
          # Collection partials keep their merged-object warning path.
          return nil if keyword_args(stmt).key?(:collection)
          partial_class = @partial_resolver.call(first.unescaped)
          return nil unless partial_class

          iface = @context.interface_for(partial_class)
          if empty_partial_interface?(partial_class, iface)
            # Naming an empty (dropped) interface as an intersection member
            # would emit a TS2305 dangling import. Returning nil routes it into
            # the remainder (merged, zero props); other members stay intact.
            warn_empty_partial(stmt, first.unescaped, "it is omitted from `#{prop_name}`'s intersection type")
            return nil
          end
          iface
        end

        def collection_attr_shortcut(args)
          return nil if args.size < 2
          first = args.first
          return nil unless first.is_a?(Prism::InstanceVariableReadNode) || first.is_a?(Prism::CallNode)
          props = symbol_args_to_properties(args)
          props.empty? ? nil : props
        end

        def prop_from_partial(node, name, args, partial, optional:)
          partial_class = @partial_resolver.call(partial)
          return build_property(name, type: "unknown", optional: optional) unless partial_class

          multi = looks_like_collection?(name, args.first)
          iface = @context.interface_for(partial_class)
          if empty_partial_interface?(partial_class, iface)
            # An empty interface is dropped from generation, so a named
            # reference would be a TS2305 dangling import. Keep the property
            # (collection-ness is known) but degrade the element to `unknown`.
            warn_empty_partial(node, partial, "`#{name}` falls back to `unknown`")
            @prewarned_props << name.to_s
            return build_property(name, type: "unknown", optional: optional, multi: multi)
          end

          build_property(name, type: iface, optional: optional, multi: multi)
        end

        # True when the partial's interface is conclusively empty (would be
        # dropped from generation). Asking `empty?` triggers the partial's own
        # walk — fine within a cycle (memoized), EXCEPT when that walk is
        # already on the stack: `Interface#properties`/`parsed` memoize
        # non-reentrantly, so re-entering would recurse to SystemStackError.
        # An in-progress walk is treated as NON-empty, which is safe by
        # construction: a partial can only be mid-walk while a reference back
        # to it resolves if one of its own statements triggered the sub-walk,
        # and every such statement emits at least one property — so the
        # finished interface can't be empty. This preserves recursive types
        # (Comment.replies → Comment). A self-referencing EMPTY partial never
        # reaches here — `handle_partial_bang`'s cycle guard returns first.
        def empty_partial_interface?(partial_class, iface)
          return false if self.class.walks_in_progress.include?(partial_class._template_path)

          iface.empty?
        end

        # One warning per reference site per cycle; the generic post-inference
        # unknown warning is suppressed for these props (`note_unknown_candidate`)
        # so the same property doesn't warn twice.
        def warn_empty_partial(node, partial_name, consequence)
          key = [@path, node.location.start_line, partial_name]
          warned = self.class.warned_empty_partials
          return if warned.include?(key)

          warned << key
          log_warning(node, "partial \"#{partial_name}\" produced no statically-typed properties; " \
            "#{consequence} — use `typelize:` to pin a type")
        end

        # Jbuilder picks array-vs-object at runtime via `each`. Statically we
        # infer from the name (plural → array), falling back to known
        # collection method names on the argument.
        def looks_like_collection?(name, node)
          return true if node.is_a?(Prism::CallNode) && COLLECTION_METHODS.include?(node.name)
          plural_name?(name)
        end

        # Words that look plural but are conceptually singular, so e.g.
        # `json.earnings @summary, partial: ...` types `Earnings`, not
        # `Array<Earnings>`. Apps can extend this via Rails' inflector
        # uncountables (`singularize` consults inflections first).
        SINGULAR_LOOKING_PLURALS = %w[news settings earnings analytics statistics series].freeze

        def plural_name?(name)
          str = name.to_s
          return false if str.empty?
          return false if SINGULAR_LOOKING_PLURALS.include?(str)
          str.singularize != str
        end

        # Positional (`json.partial! "posts/post"`) and kwargs-only
        # (`partial:`/`collection:`/`as:`) forms. At the root a collection
        # partial becomes the root array; inside a block it can't be expressed
        # (props merge into the surrounding shape), so we warn.
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

          # Merging a partial pulls in ITS properties, which walks ITS
          # template — mutually-merging templates (A merges B merges A)
          # would recurse forever. Break the cycle at the re-entrant edge.
          partial_path = partial_class._template_path
          if self.class.walks_in_progress.include?(partial_path)
            log_warning(node, "cyclic `json.partial!` merge detected " \
              "(#{partial_path} is already being walked while merging into #{@path}); " \
              "skipping this merge to break the cycle — no properties merged")
            return []
          end

          @context.interface_for(partial_class).properties
        end

        def handle_extract(node, optional:)
          args = positional_args(node)
          # `json.extract! obj, *helper_attrs` (or any non-symbol attribute
          # argument), or a splat in the object slot itself (`json.extract!
          # *attrs`) — the dynamic part is invisible statically. One warning
          # per call site; the literal symbols still extract as usual.
          if args.first.is_a?(Prism::SplatNode) || args.drop(1).any? { |a| !a.is_a?(Prism::SymbolNode) }
            log_warning(node, "`json.#{node.name}` with a dynamic attribute list (splat or non-literal " \
              "argument) cannot be statically typed; only literal attributes emitted — " \
              "use `typelize:` to pin the rest")
          end
          symbol_args_to_properties(args, optional: optional)
        end

        def symbol_args_to_properties(args, optional: false)
          args.drop(1)
            .select { |a| a.is_a?(Prism::SymbolNode) }
            .map { |sym| note_unknown_candidate(sym, property_from_column(sym.unescaped, optional: optional)) }
        end

        # `json.array! @items do |item| ... end` — emit the element shape; the
        # root-array wrapping is handled via `root_is_array`. Blockless forms
        # other than the root-level `partial:` one warn (v1 limitation).
        def handle_array_bang(node, optional:)
          if node.block.is_a?(Prism::BlockNode)
            # Root: the root array's element shape (see `detect_root_array`).
            # Nested: can't be an array on the enclosing key (like a nested
            # collection `partial!`), so warn instead of typing it as an object.
            if @nested
              log_warning(node, "`json.array!` with a block inside another block is typed as an " \
                "object, not an array — use `typelize:` to pin an array type")
            end
            shape_body(node.block)
          elsif keyword_args(node).key?(:partial)
            handle_array_partial(node, keyword_args(node)[:partial])
          elsif (args = positional_args(node)).size >= 2
            log_warning(node, "`json.array!` without a block emits its attributes as an object shape, " \
              "not an array — use the block form or `typelize:` to pin an array type")
            collection_attr_shortcut(args) || []
          else
            warn_skipped(node, "`json.array!` without a block or attribute list")
            []
          end
        end

        # Blockless `json.array! partial:` renders the partial per element. At
        # the root the element type comes from `detect_root_array_element`;
        # elsewhere (or with a dynamic reference) it can't be expressed — warn.
        def handle_array_partial(node, partial)
          unless partial.is_a?(String)
            log_warning(node, "`partial:` with a dynamic template reference cannot be resolved " \
              "statically — the array stays untyped; use `typelize:` to pin a type")
            return []
          end

          warn_skipped(node, "`json.array!` with `partial:` inside a block") if @nested
          []
        end

        def handle_passthrough(node, optional:)
          return [] unless node.block.is_a?(Prism::BlockNode)
          extract(node.block.body&.body || [], optional: optional)
        end

        # Walks an if/elsif/else (or unless/else) chain, merging same-name
        # props across branches (required only if every branch of a fully
        # covered chain emits it).
        def handle_conditional(node)
          branches, fully_covered = collect_branches(node)
          branch_props = branches.map { |body| extract(body, optional: false) }
          merge_branches(branch_props, fully_covered: fully_covered)
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

        # Merges same-name props across branches: nullability widens
        # (`Foo` + `Foo | null` → `Foo | null`); a prop is optional unless
        # every branch of a fully-covered chain emits it (or any branch marked
        # it optional). Type ambiguity isn't unioned — the first non-`null`
        # branch wins (a bare `nil` branch contributes only nullability),
        # except a `typelize:` assertion in any branch wins and carries
        # `user_asserted` through so model inference can't clobber it.
        def merge_branches(branch_props, fully_covered:)
          indexed = branch_props.map { |props| props.to_h { |p| [p.name.to_s, p] } }
          names = branch_props.flat_map { |props| props.map { |p| p.name.to_s } }.uniq
          names.map do |name|
            occurrences = indexed.map { |idx| idx[name] }
            present = occurrences.compact
            base = present.find(&:user_asserted) ||
              present.find { |p| !null_type?(p) } || present.first
            optional = present.any?(&:optional) || !(fully_covered && occurrences.all?)
            base.with(optional: optional, nullable: widened_nullable(base, present))
          end
        end

        # Nullability widens across merged occurrences: an explicit `nullable`
        # flag, or a branch emitting a bare `nil` (typed "null") when the base
        # is something else (`string` + `null` → `string | null`). If the base
        # is itself the `null` literal, no extra `| null` (avoids `null | null`).
        def widened_nullable(base, occurrences)
          occurrences.any?(&:nullable) ||
            (!null_type?(base) && occurrences.any? { |p| null_type?(p) })
        end

        def null_type?(prop)
          (prop.type.is_a?(String) || prop.type.is_a?(Symbol)) && prop.type.to_s == "null"
        end

        # With an inferable (AR) model the type stays nil so model inference
        # resolves it (nested shapes only infer nil-typed props, so a premature
        # hint would block the column type). Without a model, name hints are
        # the best signal.
        def property_from_column(col, optional: false)
          build_property(col, type: @column_inference ? nil : name_hint(col), optional: optional)
        end

        def build_property(name, type: nil, optional: false, nullable: false, multi: false, additional_types: nil, user_asserted: false)
          Property.new(
            name: name,
            type: type,
            optional: optional,
            nullable: nullable,
            multi: multi,
            column_name: name,
            additional_types: additional_types,
            user_asserted: user_asserted
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

        # Registers a local name as an alias for the json builder for the
        # duration of the block (nestable via a stack). See `json_call?`.
        def with_json_alias(name)
          (@json_aliases ||= []).push(name) if name
          yield
        ensure
          @json_aliases.pop if name
        end

        # The block parameter jbuilder binds the builder to in an object block
        # (`json.foo do |json| ... end`); nil when the block takes no simple
        # positional parameter.
        def block_builder_alias(block_node)
          params = block_node.parameters
          return nil unless params.is_a?(Prism::BlockParametersNode)

          first = params.parameters&.requireds&.first
          first.name if first.is_a?(Prism::RequiredParameterNode)
        end

        def warn_skipped(node, construct)
          log_warning(node, "#{construct} cannot be statically typed; no property emitted — " \
            "use `typelize:` to pin a type")
        end

        def log_warning(node, message)
          Typelizer.logger.warn("Typelizer::Jbuilder: #{@path}:#{node.location.start_line}: #{message}")
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

        # A `json.<name> ...` call. The receiver is normally the bare `json`
        # method; inside an object block jbuilder yields the builder to the
        # block param, rebinding it to a local (`do |json| json.name ... end`),
        # so a local read of a registered builder alias counts too.
        def json_call?(node)
          return false unless node.is_a?(Prism::CallNode)

          receiver = node.receiver
          (receiver.is_a?(Prism::CallNode) && receiver.name == :json && receiver.receiver.nil?) ||
            (receiver.is_a?(Prism::LocalVariableReadNode) && json_alias?(receiver.name))
        end

        def json_alias?(name)
          @json_aliases&.include?(name)
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
