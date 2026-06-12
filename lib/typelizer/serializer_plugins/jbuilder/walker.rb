# frozen_string_literal: true

require "digest"
require "set"

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
        # Per-cycle dedup for the post-inference "unknown" warnings (keys:
        # [template path, prop name, line]). Multiple writers build their own
        # Interface for the same template within one generation cycle; the
        # warning should fire once per template+prop per cycle, so the set
        # lives here and is cleared together with the parse cache.
        @warned_unknowns = Set.new
        class << self
          attr_reader :parse_cache, :warned_unknowns

          # Content-keyed (path + source digest, matching the writer's
          # fingerprint-digest house style): the per-cycle `reset_cache!`
          # makes within-cycle reuse safe, and the digest keeps long-lived
          # processes honest — explicit-discover flows that never reset
          # still re-parse an edited template automatically (the stale
          # entry is evicted so the cache never accretes old parses).
          # Cascade invalidation for composed partials needs nothing extra:
          # a partial's properties are re-walked through its parent's
          # Interface every cycle, so its fresh parse flows upward.
          def parsed_tree(path)
            digest = Digest::SHA256.file(path).hexdigest
            key = [path, digest]
            parse_cache.delete_if { |(cached_path, cached_digest), _| cached_path == path && cached_digest != digest }
            parse_cache[key] ||= Prism.parse_file(path).value
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
              break unless node.is_a?(Prism::CallNode) && node.receiver.nil?
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

        # --- Internal widening registries ------------------------------------
        # Table-driven on purpose (a future inertia-builder / props_template
        # adapter is one entry away), but deliberately module-private: no
        # registration API is exposed until a real second adapter exists.
        # These are frozen constants — code, not per-discovery state — so
        # `Typelizer::Jbuilder.reset!` cycles never touch them.
        #
        # The directive vocabulary mirrors jbuilder-inertia's
        # `JbuilderInertia::PropBuilder::KNOWN_DIRECTIVES` (defer, optional,
        # merge, once, always, scroll). Only `defer` and `optional` may omit
        # the key from the initial Inertia page load, so only they widen the
        # generated property to optional.
        INERTIA_WIDENING_DIRECTIVES = %i[defer optional].freeze
        private_constant :INERTIA_WIDENING_DIRECTIVES

        # kwarg name → resolver lambda deciding optionality from the kwarg's
        # literal value. Handles the symbol (`inertia: :defer`), array
        # (`inertia: [:defer, :merge]`), and hash
        # (`inertia: {defer: {group: "x"}}`) forms. Non-widening directives
        # (merge/always/once/scroll) and unrecognized shapes never widen.
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
          @unknown_lines = {}
        end

        def properties
          parsed.fetch(:properties)
        end

        def root_is_array
          parsed.fetch(:root_is_array)
        end

        # prop name → source line for properties whose walker-side type is
        # nil or "unknown". These are CANDIDATE unknowns: model inference
        # runs after the walk (`Interface#infer_types`) and can still rescue
        # them, so the actual warning decision is made post-inference by
        # `Plugin#after_type_inference` — this map only supplies the
        # file:line the walker alone knows.
        def unknown_candidates
          parsed
          @unknown_lines
        end

        private

        def parsed
          @parsed ||= begin
            stmts = self.class.parsed_tree(@path).statements.body
            {
              root_is_array: detect_root_array(stmts),
              properties: extract(stmts, optional: false)
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
          else note_unknown_candidate(node, handle_prop(node, optional: optional))
          end
        end

        # Records the source line of a property the walker could not type
        # (type nil — delegated to model inference — or a hard "unknown").
        # No warning is logged here: a bound model's columns can still fill
        # the type in post-walk, so warning at this point would cry wolf.
        def note_unknown_candidate(node, prop)
          return prop unless prop.is_a?(Property)

          if !prop.user_asserted && self.class.unknown_type?(prop.type)
            @unknown_lines[prop.name.to_s] ||= node.location.start_line
          end
          prop
        end

        def handle_prop(node, optional:)
          name = node.name.to_s
          args = positional_args(node)
          kwargs = keyword_args(node)
          optional ||= kwargs.any? { |key, value| OPTIONAL_KWARG_RESOLVERS[key]&.call(value) }

          value = args.first
          if (resolver = value_node_resolver(value))
            optional ||= resolver[:widening].include?(value.name)
            # Resolver blocks contain arbitrary Ruby returning a plain value —
            # never jbuilder DSL — so the block is NOT walked as a shape. Its
            # final expression feeds the regular expression-inference path
            # below (literals, Time calls); anything else falls through to
            # name hints and, when a model is bound, column inference.
            value = resolver_value_expression(value)
          end

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

          if value
            inferred = infer_type(value, name: name)
            return build_property(name, type: inferred, optional: optional, nullable: inferred == "null")
          end

          if resolver
            # Resolver with no inferable block expression: keep the name-hint
            # signal instead of a hard "unknown".
            return build_property(name, type: guess_from_name(name), optional: optional)
          end

          build_property(name, type: "unknown", optional: optional)
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
        # the resolver will produce at runtime.
        def resolver_value_expression(node)
          node.block&.body&.body&.last
        end

        # Routes `typelize:` overrides through TypeParser so shortcuts
        # (`string?`, `number[]`, `string?[]`) expand into real TS. The
        # property is flagged `user_asserted` so `Interface#infer_types`
        # skips AR model inference for it — scoped to this exact property,
        # at this exact nesting level, with no class-level registry.
        # Optionality merges the user's assertion (`string?`) with structural
        # optionality (from `if` blocks, inertia kwargs) so context-aware
        # passes like `merge_branches` can still widen it.
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

        # Composed-partial blocks emit named intersections — this is how
        # jbuilder fakes Alba's named-trait composition:
        #
        #   json.course do                       course: Course & CourseDetails
        #     json.partial! "courses/course"
        #     json.partial! "courses/course_details"
        #   end
        #
        # Every top-level `json.partial!` with a resolvable string-literal
        # reference becomes a named imported interface; whatever else the
        # block contains (own props, conditionals, dynamic/collection
        # partials) is extracted as usual and trails the intersection as an
        # inline `Shape` (`Course & { progress: number }`) — structurally
        # equivalent to inlining the partial's fields, just named. Blocks
        # with no nameable partials stay plain inline `Shape`s so AR model
        # inference (column types, enums) keeps working inside nested blocks
        # via `infer_nested_property_types`.
        def handle_prop_with_block(node, name:, optional:)
          multi = !node.block.parameters.nil?
          interfaces, rest = partition_composed_partials(node.block)
          if interfaces.any?
            additional = interfaces.drop(1)
            rest_props = with_nested { extract(rest, optional: false) }
            additional += [Shape.new(properties: rest_props)] if rest_props.any?
            return build_property(name, type: interfaces.first, additional_types: additional, optional: optional, multi: multi)
          end
          build_property(name, type: Shape.new(properties: shape_body(node.block)), optional: optional, multi: multi)
        end

        # Splits a block body into [named partial interfaces, other stmts].
        # Only a top-level `json.partial!` with a string-literal reference,
        # no `collection:` kwarg, and a resolvable template counts as a named
        # member; everything else (including unresolvable partials, which the
        # regular extraction path warns about) stays in the remainder.
        def partition_composed_partials(block_node)
          interfaces = []
          rest = []
          (block_node.body&.body || []).each do |stmt|
            if (iface = nameable_partial_interface(stmt))
              interfaces << iface
            else
              rest << stmt
            end
          end
          [interfaces.uniq, rest]
        end

        def nameable_partial_interface(stmt)
          return nil unless json_call?(stmt) && stmt.name == :partial!
          first = positional_args(stmt).first
          return nil unless first.is_a?(Prism::StringNode)
          # Collection partials keep their merged-object warning path.
          return nil if keyword_args(stmt).key?(:collection)
          partial_class = @partial_resolver.call(first.unescaped)
          partial_class && @context.interface_for(partial_class)
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
            .map { |sym| note_unknown_candidate(sym, property_from_column(sym.unescaped, optional: optional)) }
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
        # wins, except that an explicit `typelize:` assertion in any branch
        # beats inferred guesses (and carries `user_asserted` through the
        # merge, so model inference can't clobber the merged property).
        def merge_branches(branch_props, fully_covered:)
          names = branch_props.flat_map { |props| props.map(&:name) }.uniq
          names.map do |name|
            occurrences = branch_props.map { |props| props.find { |p| p.name == name } }
            present = occurrences.compact
            base = present.find(&:user_asserted) || present.first
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
