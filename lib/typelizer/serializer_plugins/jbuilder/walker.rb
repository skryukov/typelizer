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
        # Per-cycle dedup for syntax-error warnings, keyed by
        # [path, line, message].
        @warned_syntax_errors = Set.new
        class << self
          attr_reader :parse_cache, :warned_unknowns, :walks_in_progress, :warned_empty_partials, :warned_syntax_errors

          def parsed_tree(path)
            parse_entry(path).fetch(:tree)
          end

          # Prism recovers from syntax errors with a PLAUSIBLE-but-wrong tree
          # (e.g. a missing `end` folds trailing statements under the
          # unclosed block) — callers must check these before trusting the
          # tree, or every emitted type is a silent lie.
          def syntax_errors(path)
            parse_entry(path).fetch(:errors)
          end

          # Digest-keyed parse cache. Within a cycle reuse is safe
          # (`reset_cache!` clears it); across cycles the digest
          # auto-invalidates an edited template, so long-lived processes never
          # serve a stale parse. The source is read once, then digested and
          # parsed from that one string (no read/parse race); an unreadable
          # template raises a named `Typelizer::Error` (`metadata_for`
          # swallows it, the property walk re-raises).
          def parse_entry(path)
            content = begin
              File.read(path)
            rescue SystemCallError => e
              raise Typelizer::Error,
                "Typelizer::Jbuilder: could not read template #{path} (#{e.class}: #{e.message})"
            end

            digest = Digest::SHA256.hexdigest(content)
            entry = parse_cache[path]
            return entry if entry && entry[:digest] == digest

            result = Prism.parse(content)
            parse_cache[path] = {digest: digest, tree: result.value, errors: result.errors}
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
            # A syntax-errored template warns (once) via the property walk;
            # metadata from a recovered tree isn't trustworthy either.
            return result if syntax_errors(path).any?

            tree.statements.body.each do |node|
              # Scan every top-level bare call, not just the leading run: a
              # `typelize_as`/`typelize_from` after a `json.*` line (which has a
              # receiver) must still be picked up rather than silently dropped.
              next unless node.is_a?(Prism::CallNode) && node.receiver.nil?
              arg = unwrap_parens(node.arguments&.arguments&.first)
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
            @warned_syntax_errors = Set.new
          end

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

        # A rendered array type for the spots where the Property-level `multi`
        # flag can't express array-ness: one side of a re-set union (an array
        # block conditionally re-set with a scalar renders
        # `Array<X> | string`, never `Array<X | string>`) and the element of
        # a nested array (`json.child!` inside a collection-value block —
        # `Array<Array<X>>`). Renders as `Array<element>` via `to_s`;
        # `map_element_shape` lets type inference and the post-inference
        # unknown warning recurse into a Shape element the same way they walk
        # plain Shape members (duck-typed, so nothing eager-loaded needs this
        # lazily-loaded class).
        class ArrayOf
          attr_reader :element

          def initialize(element)
            @element = element
            freeze
          end

          def map_element_shape(&block)
            case element
            when Shape then self.class.new(yield(element))
            when Array then self.class.new(element.map { |m| m.is_a?(Shape) ? yield(m) : m })
            else self
            end
          end

          def to_s
            members = element.is_a?(Array) ? element : [element]
            "Array<#{members.map { |m| render_member(m) }.join(" | ")}>"
          end

          def ==(other)
            other.is_a?(self.class) && element == other.element
          end
          alias_method :eql?, :==

          def hash
            [self.class, element].hash
          end

          private

          def render_member(member)
            case member
            when Shape then member.to_s
            when nil then "unknown"
            else member.respond_to?(:name) ? member.name : member.to_s
            end
          end
        end

        # A union member whose type is delegated to model inference: an
        # occurrence the walker folded in with `type: nil` (an `extract!`-ed
        # column unioned with, say, a conditional literal). Dropping it (or
        # locking the merged prop) silently narrowed the union to the literal
        # side — the column's real type must survive.
        #
        # INTERNAL ONLY: `TypeInference#resolve_deferred_members` (which we
        # also own) replaces every marker with the model-inferred column type
        # before `Interface`-level consumers (render, imports, fingerprint,
        # OpenAPI) ever see the property, honoring the union-member contract
        # (String/Symbol/Shape/ArrayOf/Interface). The duck method
        # `typelizer_deferred_inference?` is how that eager-loaded module
        # detects markers without referencing this lazily-loaded class;
        # `to_s` is a pure safety net.
        class DeferredInference
          attr_reader :column_name

          def initialize(column_name)
            @column_name = column_name.to_s
            freeze
          end

          def typelizer_deferred_inference?
            true
          end

          # Maps the model-inferred probe property back to a contract-safe
          # union member: the column type (array columns keep their wrapper),
          # or "unknown" when inference came up empty — the plugin's
          # post-inference warning picks those up.
          def resolved_member(probe)
            type = probe.type
            return "unknown" if type.nil?

            type = type.to_s if type.is_a?(Symbol)
            probe.multi ? ArrayOf.new(type) : type
          end

          def ==(other)
            other.is_a?(self.class) && column_name == other.column_name
          end
          alias_method :eql?, :==

          def hash
            [self.class, column_name].hash
          end

          def to_s
            "unknown"
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
          # Nesting path of the property currently being walked (prop names of
          # the enclosing blocks) — keys `@unknown_lines` so two same-named
          # unknowns at different nesting levels each get their own line.
          @name_stack = []
          # Prop names that fell back to `unknown` but already warned at walk
          # time with a more specific message (an empty `partial:` reference,
          # a value-less `typelize:`), so the generic post-inference unknown
          # warning is suppressed for them.
          @prewarned_props = Set.new
          # Object identities of array props built from a VALUELESS
          # `json.<name> do json.child! ... end` block: at render these go
          # through jbuilder's `_merge_block`, whose Array+Array branch
          # CONCATENATES onto an existing array instead of replacing it —
          # `merge_reset` needs to know which occurrences those are (see
          # `merge_block_concat?`). Identity-keyed because the (multi, type)
          # pair alone can't distinguish this form from a collection-value
          # block, which replaces.
          @merge_block_arrays = Set.new
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

        # Dot-joined nesting path ("a.b.name") → source line for properties
        # whose walker-side type is nil or "unknown". These are CANDIDATE
        # unknowns: model inference runs after the walk
        # (`Interface#infer_types`) and can still rescue them, so the actual
        # warning decision is made post-inference by
        # `Plugin#after_type_inference` — this map only supplies the
        # file:line the walker alone knows. Path-keyed so two same-named
        # unknowns at different nesting levels each warn with their own line.
        def unknown_candidates
          parsed.fetch(:unknown_lines)
        end

        private

        def parsed
          @parsed ||= begin
            self.class.walks_in_progress.add(@path)
            begin
              if (error = self.class.syntax_errors(@path).first)
                # Prism's recovered tree is plausible-but-wrong (a missing
                # `end` folds trailing props under the unclosed block) —
                # walking it would emit silently wrong types. Warn and emit
                # nothing instead.
                warn_syntax_error(error)
                {root_is_array: false, root_array_element: nil, properties: [], unknown_lines: {}}
              else
                stmts = self.class.parsed_tree(@path).statements.body
                # Assigned before `extract` so `handle_array_bang` /
                # `handle_partial_bang` can distinguish "conditional root
                # array in an object template" (pre-warned, dropped) from a
                # second root array CONCATENATED onto an existing one.
                @root_is_array = detect_root_array(stmts)
                properties = extract(stmts, optional: false)
                if @root_array_concat
                  # jbuilder CONCATENATES a second root `json.array!` onto
                  # the first (`_merge_values(Array, Array)`): the element
                  # type is the union of every form's shape. A flat property
                  # list can't hold that union, so every element key widens
                  # to optional — any single element carries only its own
                  # form's keys.
                  properties = properties.map { |p| p.with(optional: true) }
                end
                {
                  root_is_array: @root_is_array,
                  root_array_element: @root_is_array ? detect_root_array_element(stmts) : nil,
                  # Populated as a side effect of `extract` above (see
                  # `note_unknown_candidate`); captured here so `unknown_candidates`
                  # reads it through `parsed` like every other derived value.
                  properties: properties,
                  unknown_lines: @unknown_lines
                }
              end
            ensure
              self.class.walks_in_progress.delete(@path)
            end
          end
        end

        # Once per cycle per error site (each writer re-walks the template
        # through a fresh Walker instance).
        def warn_syntax_error(error)
          line = error.location.start_line
          key = [@path, line, error.message]
          warned = self.class.warned_syntax_errors
          return if warned.include?(key)

          warned << key
          Typelizer.logger.warn(
            "Typelizer::Jbuilder: #{@path}:#{line}: template has a Ruby syntax error " \
            "(#{error.message}); skipping type generation for it — no properties emitted"
          )
        end

        # Only top-level statements are inspected (v1), but cache wrappers are
        # transparent (see `expand_root_passthrough`). A root `array!` /
        # collection `partial!` under a conditional can't be expressed, so the
        # root stays an object and we warn instead of mistyping.
        def detect_root_array(stmts)
          stmts = expand_root_passthrough(stmts)
          return true if stmts.any? { |n| root_array_call?(n) }

          warn_on_conditional_root_array(stmts)
          false
        end

        # `cache!`/`cache_if!`/`cache_root!` wrap their block transparently at
        # render time (the cached fragment merges into the current scope), so
        # a root array inside one still makes the ROOT an array. Property
        # extraction goes through `handle_passthrough`; this mirrors that
        # transparency for root-shape scanning.
        def expand_root_passthrough(stmts)
          stmts.flat_map do |node|
            if json_call?(node) && PASSTHROUGH_CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode)
              expand_root_passthrough(node.block.body&.body || [])
            else
              [node]
            end
          end
        end

        def root_array_call?(node)
          return false unless json_call?(node)

          (node.name == :array! && (node.block || keyword_args(node)[:partial].is_a?(String) ||
            collection_attr_shortcut(positional_args(node)))) ||
            # jbuilder's `json.(collection) { |el| ... }` — `call` with a block
            # is `_array(object, &block)`, the root-array form.
            (node.name == :call && !node.block.nil?) ||
            (node.name == :partial! && keyword_args(node).key?(:collection))
        end

        # Blockless `json.array! @xs, partial: "xs/x"` at the root: the element
        # type is the partial's named interface, rendering
        # `type X = Array<Element>;`. Unresolvable or empty partials warn and
        # fall back to `Array<unknown>` (naming an empty interface would emit a
        # dangling TS2305 import).
        def detect_root_array_element(stmts)
          node = expand_root_passthrough(stmts).find { |n| root_array_partial_call?(n) }
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

        # Recurses through arbitrarily nested conditionals (and cache wrappers
        # inside them) so a doubly-nested root array still warns.
        def warn_on_conditional_root_array(stmts)
          stmts.each do |node|
            next unless node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            branches, _ = collect_branches(node)
            branches.each do |branch|
              expand_root_passthrough(branch).each do |n|
                if root_array_call?(n)
                  log_warning(n, "a root array (`json.array!` / collection `json.partial!`) inside a conditional " \
                    "is typed as an object — conditional root arrays are not supported; " \
                    "use `typelize:` to pin the type")
                elsif n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode)
                  warn_on_conditional_root_array([n])
                end
              end
            end
          end
        end

        def extract(stmts, optional:)
          merge_same_level(stmts.flat_map { |n| extract_one(n, optional: optional) }.compact)
        end

        # Collapses same-name properties emitted at one level (an
        # unconditional `json.foo` plus a conditional re-emit, or an own prop
        # alongside a merged partial's) into one TS key, following jbuilder's
        # re-set semantics in statement order:
        #
        # - a later UNCONDITIONAL write replaces the value (last-wins:
        #   `json.status 1` then `json.status "active"` renders the string —
        #   including an own prop overriding a merged partial's, and
        #   including an earlier `typelize:` assertion whose value never
        #   survives to render: that assertion is dead)
        # - two object blocks DEEP-MERGE per key (jbuilder's `_merge_block`)
        # - a later CONDITIONAL write may or may not run, so it unions with
        #   what's there (a surviving assertion stays asserted); a
        #   conditional bare `nil` contributes nullability
        def merge_same_level(props)
          return props if props.map { |p| p.name.to_s }.uniq.size == props.size

          props.group_by { |p| p.name.to_s }.values.map do |occurrences|
            occurrences.reduce { |acc, incoming| merge_reset(acc, incoming) }
          end
        end

        # One re-set step: `acc` is what accumulated so far, `incoming` the
        # next same-name write in statement order. Each occurrence is folded
        # as its FULL rendered type — type + multi + nullable +
        # optional (≙ conditional) + user_asserted — mirroring what jbuilder
        # does with the rendered VALUE at runtime: an unconditional write is
        # `_set_value` (replace) or `_merge_block` (object deep-merge); a
        # conditional write forks the runtime into ran/didn't-run, i.e. a
        # union of the folded result with the accumulator.
        def merge_reset(acc, incoming)
          if merge_block_concat?(acc, incoming)
            # A valueless `json.<key> do json.child! ... end` block over an
            # array-valued key goes through jbuilder's `_merge_block`, whose
            # Array+Array branch CONCATENATES — elements of BOTH shapes occur.
            concat_merge(acc, incoming, conditional: incoming.optional)
          elsif !incoming.optional
            # Unconditional: this write always happens at runtime — it
            # replaces a scalar or deep-merges into an existing object.
            if shape_pair?(acc, incoming)
              incoming.with(
                type: deep_merge_shapes(acc.type, incoming.type, incoming_optional: false, earlier_optional: acc.optional),
                optional: false
              )
            elsif union_with_mergeable_members?(acc) && object_block?(incoming) && !incoming.user_asserted
              merge_block_over_union(acc, incoming)
            else
              incoming.with(optional: false)
            end
          elsif shape_pair?(acc, incoming)
            acc.with(
              type: deep_merge_shapes(acc.type, incoming.type, incoming_optional: true, earlier_optional: acc.optional),
              nullable: acc.nullable || incoming.nullable
            )
          elsif null_type?(incoming)
            # A conditional bare `nil` contributes nullability, not type; a
            # `null`-typed accumulator already covers it (no `null | null`).
            # This holds for intersection (composed-partial) accumulators
            # too: `&` binds tighter than `|` in TS, so the rendered
            # `A & B | null` is exactly `(A & B) | null` — no degrade needed.
            null_type?(acc) ? acc : acc.with(nullable: true)
          elsif null_type?(acc)
            # Unconditional `nil` then a conditional real write: <real> | null.
            incoming.with(optional: acc.optional, nullable: true)
          elsif acc.additional_types&.any? || incoming.additional_types&.any?
            # An intersection type (composed-partial block) conditionally
            # re-set with a non-null member has no faithful rendering:
            # `Property#render` joins the union FIRST and appends the
            # intersection members after (`A | string & B`), which TS binds
            # as `A | (string & B)` — silently wrong. Warn and emit
            # `unknown` instead.
            warn_merge("`#{acc.name}` conditionally re-sets a composed-partial (intersection) " \
              "type; the resulting union is not statically expressible — emitted `unknown`; " \
              "use `typelize:` to pin the type")
            build_property(acc.name, type: "unknown", optional: acc.optional)
          else
            merged_type, merged_multi = union_of(acc, incoming)
            # A delegated (nil-typed) occurrence keeps the merged prop OPEN
            # to inference: locking it would strand the DeferredInference
            # member unresolved and silently narrow the union to the
            # literal side.
            delegated = [acc, incoming].any? { |p| !p.multi && p.type.nil? }
            acc.with(
              type: merged_type,
              multi: merged_multi,
              nullable: acc.nullable || incoming.nullable,
              user_asserted: acc.user_asserted || incoming.user_asserted,
              inference_locked: !delegated && (acc.inference_locked || incoming.inference_locked)
            )
          end
        end

        # Deep-merge only applies to two OBJECT blocks; array blocks
        # (`multi`) are replaced whole by jbuilder's `_set_value`.
        def shape_pair?(a, b)
          a.type.is_a?(Shape) && b.type.is_a?(Shape) && !a.multi && !b.multi
        end

        def object_block?(prop)
          prop.type.is_a?(Shape) && !prop.multi
        end

        # A union holding at least one member that renders as a HASH at
        # runtime (an inline Shape or a named partial's Interface) — the
        # members jbuilder's `_merge_block` would deep-merge into rather
        # than crash on.
        def union_with_mergeable_members?(prop)
          !prop.multi && prop.type.is_a?(Array) &&
            prop.type.any? { |m| m.is_a?(Shape) || interface_like?(m) }
        end

        # jbuilder's `_merge_block` over a union-valued key: an UNCONDITIONAL
        # object block deep-merges into whatever the key currently holds.
        # Shape members (hashes at render) deep-merge; scalar, array, and
        # delegated members raise `Jbuilder::MergeError` (a bare-nil current
        # raises `NullError`) at render, so no successful render contains
        # them — they drop from the union. Verified against jbuilder 2.15.1:
        # `{id}`-block + conditional `"anon"` + `{bio}`-block renders
        # `{id, bio}` or crashes; the emitted type is the merged shape(s).
        # A named partial reference also deep-merges at render (it's a hash),
        # but `Interface & Shape` inside a union isn't statically
        # expressible — warn and degrade to `unknown` instead of silently
        # narrowing.
        def merge_block_over_union(acc, incoming)
          if acc.type.any? { |m| interface_like?(m) }
            warn_merge("`#{acc.name}` re-sets a union containing a named partial reference " \
              "with an object block; the deep-merged result is not statically expressible — " \
              "emitted `unknown`; use `typelize:` to pin the type")
            return build_property(acc.name, type: "unknown", optional: acc.optional)
          end

          merged = acc.type.filter_map do |member|
            next unless member.is_a?(Shape)

            deep_merge_shapes(member, incoming.type, incoming_optional: false, earlier_optional: acc.optional)
          end.uniq
          incoming.with(type: (merged.size == 1) ? merged.first : merged, optional: false)
        end

        def interface_like?(member)
          !member.is_a?(Shape) && member.respond_to?(:properties)
        end

        # jbuilder concatenates only when the INCOMING write is a valueless
        # `child!` block (`_merge_block` → `_merge_values(Array, Array)`) and
        # the key currently holds an array — either a plain array occurrence
        # (`multi`) or a union with array members. Collection-VALUE blocks
        # replace instead (`_set` → `_set_value`), so they never take this
        # path.
        def merge_block_concat?(acc, incoming)
          merge_block_array?(incoming) &&
            (acc.multi || (!acc.multi && acc.type.is_a?(Array) && acc.type.any?(ArrayOf)))
        end

        # Element-type union for a render-time array CONCAT (verified against
        # jbuilder 2.15.1): the merged property stays an array whose element
        # type is the union of both sides' element types — `Array<A | B>`,
        # never `Array<A> | Array<B>` and never a replacement. On a union
        # accumulator the new elements join every array member; scalar
        # members survive only when the incoming block is conditional (an
        # unconditional merge-block over a scalar raises
        # `Jbuilder::MergeError`, so those members can't produce output).
        def concat_merge(acc, incoming, conditional:)
          new_elements = element_members(incoming)
          members = union_members(acc).filter_map do |member|
            if member.is_a?(ArrayOf)
              ArrayOf.new(fold_element_members(arrayof_members(member) + new_elements))
            elsif conditional
              member
            end
          end.uniq
          type, multi = fold_members(members)
          acc.with(
            type: type,
            multi: multi,
            optional: conditional ? acc.optional : false,
            nullable: conditional ? (acc.nullable || incoming.nullable) : incoming.nullable
          )
        end

        # Element types contributed by one array-valued occurrence.
        def element_members(prop)
          prop.type.is_a?(Array) ? prop.type : [prop.type || "unknown"]
        end

        def arrayof_members(array_of)
          array_of.element.is_a?(Array) ? array_of.element : [array_of.element]
        end

        def fold_element_members(members)
          members = members.uniq
          (members.size == 1) ? members.first : members
        end

        # jbuilder `_merge_block`: keys merge recursively — a later write to
        # an existing key follows the same re-set rules. Keys arriving from a
        # CONDITIONAL later block count as conditional writes; the mirror
        # holds too: when the EARLIER block was conditional, its keys may be
        # absent from a render where only the later block ran, so they widen
        # to optional unless the later block re-sets them unconditionally.
        def deep_merge_shapes(earlier, later, incoming_optional:, earlier_optional: false)
          merged = earlier.properties.each_with_object({}) do |p, h|
            h[p.name.to_s] = earlier_optional ? preserve_merge_block_marker(p, p.with(optional: true)) : p
          end
          later.properties.each do |prop|
            key = prop.name.to_s
            prop = preserve_merge_block_marker(prop, prop.with(optional: true)) if incoming_optional
            merged[key] = merged.key?(key) ? merge_reset(merged[key], prop) : prop
          end
          Shape.new(properties: merged.values)
        end

        # The union of two occurrences' RENDERED types: `multi` wraps its own
        # occurrence's member (`Array<X> | string`), members dedupe, and a
        # single surviving member folds back into the plain type/multi
        # representation. Returns [type, multi].
        def union_of(acc, incoming)
          fold_members((union_members(acc) + union_members(incoming)).uniq)
        end

        # [type, multi] for a deduped member list: a sole ArrayOf unwraps to
        # the plain multi representation; a sole DeferredInference marker
        # folds back to a bare nil type (both sides delegated to the same
        # column — whole-prop model inference fills it in, exactly like a
        # single occurrence).
        def fold_members(members)
          return [nil, false] if members.empty?
          return [members, false] if members.size > 1

          member = members.first
          return [nil, false] if member.is_a?(DeferredInference)

          member.is_a?(ArrayOf) ? [member.element, true] : [member, false]
        end

        # A nil type (delegated to model inference) becomes a marker member:
        # `TypeInference#resolve_deferred_members` swaps it for the column's
        # inferred type post-walk, so the delegated side of the union is
        # never silently dropped.
        def union_members(prop)
          return [ArrayOf.new(prop.type || "unknown")] if prop.multi
          return [DeferredInference.new(prop.column_name || prop.name)] if prop.type.nil?

          Array(prop.type)
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
          when :extract! then handle_extract(node, optional: optional)
          when :call
            # jbuilder's `call`: with a block it is `_array(object, &block)`
            # (the root-array form — see `root_array_call?`); blockless it is
            # `extract!(object, *attributes)`.
            node.block ? handle_array_bang(node, optional: optional) : handle_extract(node, optional: optional)
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
            @unknown_lines[unknown_key(prop.name)] ||= node.location.start_line
          end
          prop
        end

        def unknown_key(name)
          (@name_stack + [name.to_s]).join(".")
        end

        # Tracks the nesting path for `unknown_key` while a named block's
        # contents are walked.
        def with_name(name)
          @name_stack.push(name.to_s)
          yield
        ensure
          @name_stack.pop
        end

        # `name:`/`args:` overrides let `json.set!` with a literal key reuse
        # this path — it's `json.<key> ...` spelled differently: name from the
        # first arg, remaining args behave like a normal prop's.
        def handle_prop(node, optional:, name: node.name.to_s, args: positional_args(node))
          kwargs = keyword_args(node)
          optional ||= kwargs.any? { |key, value| OPTIONAL_KWARG_RESOLVERS[key]&.call(value) }

          value = self.class.unwrap_parens(args.first)
          if (resolver = value_node_resolver(value))
            optional ||= resolver[:widening].include?(value.name)
            # The resolver block is arbitrary Ruby returning a plain value
            # (never DSL), so it isn't walked as a shape; its final expression
            # feeds the normal inference path below.
            value = resolver_value_expression(value)
          end

          if (override = kwargs[:typelize])
            if !literal_override?(override)
              # A non-literal `typelize:` (constant, variable, method call)
              # cannot be honored statically — fall through to normal
              # inference instead of stringifying a Prism node.
              log_warning(node, "`typelize:` with a non-literal value cannot be honored; " \
                "falling back to type inference — use a literal type (e.g. `typelize: \"string\"`)")
            elsif unbalanced_override?(override)
              # Emitted verbatim this would be syntactically broken TS that
              # only tsc catches, far from the template.
              log_warning(node, "`typelize:` value #{override.to_s.inspect} has unbalanced " \
                "brackets, braces, or quotes and would emit broken TypeScript; " \
                "falling back to type inference")
            elsif args.any? || node.block
              return property_from_override(name, override, optional: optional)
            else
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

          if (collection_props = with_name(name) { collection_attr_shortcut(args) })
            # Array-vs-object follows the same runtime heuristic as the partial
            # form (`prop_from_partial`): jbuilder emits an array only when the
            # value is a collection, so a singular name stays an object.
            multi = looks_like_collection?(name, args.first)
            return build_property(name, type: Shape.new(properties: collection_props), optional: optional, multi: multi)
          end

          if value
            inferred = infer_value(value, name: name)
            return build_property(
              name,
              type: inferred[:type],
              nullable: inferred[:nullable],
              optional: optional,
              inference_locked: inferred[:locked]
            )
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

        DELIMITER_PAIRS = {"{" => "}", "[" => "]", "(" => ")", "<" => ">"}.freeze
        private_constant :DELIMITER_PAIRS

        # Cheap syntactic sanity check for a `typelize:` string: unbalanced
        # brackets/braces/quotes. Skips quoted content (string-literal types
        # may contain brackets) and the `>` of `=>` arrows.
        def unbalanced_override?(override)
          stack = []
          quote = nil
          prev = nil
          override.to_s.each_char do |ch|
            if quote
              quote = nil if ch == quote
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
          if args.first.is_a?(Prism::SplatNode)
            # jbuilder's `_set` sees a splat's ELEMENTS: empty splat + block
            # renders an object, non-empty an array — undecidable statically.
            log_warning(node, "a splat value with a block renders an array only when the splat " \
              "is non-empty at runtime — typed as an array; use `typelize:` to pin the type")
          end
          # An object block (no value) is yielded the builder itself — its
          # param (or `it`/`_1`) aliases the builder. Array blocks are yielded
          # the ELEMENT — their param shadows any same-named outer alias.
          warn_shadowed_builder_param(node) if multi
          with_name(name) do
            with_block_scope(node.block, yields_builder: !multi) do
              children, non_children = partition_child_bangs(node.block)
              if children.any?
                next handle_child_array(node, name: name, optional: optional, children: children,
                  rest: non_children, collection_value: multi)
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
        def handle_child_array(node, name:, optional:, children:, rest:, collection_value: false)
          if rest.any?
            log_warning(node, "mixing `json.child!` with named properties is not statically typeable; " \
              "typing the array elements only — use `typelize:` to pin the full type")
          end

          branch_props = children.map do |child|
            next [] unless child.block.is_a?(Prism::BlockNode)

            # `json.child!` yields self, so its block param (or `it`/`_1`)
            # aliases the builder like an object block's.
            with_block_scope(child.block, yields_builder: true) { shape_body(child.block) }
          end
          merged = merge_branches(branch_props, fully_covered: true)
          element = Shape.new(properties: merged)
          # A collection VALUE (`json.comments @comments do |c| json.child! …`)
          # renders one scope per element, and `child!` turns EACH scope into
          # an array — array of arrays at runtime, `Array<Array<…>>` here.
          element = ArrayOf.new(element) if collection_value
          prop = build_property(name, type: element, optional: optional, multi: true)
          # Only the valueless form is `_merge_block`-ed (and so CONCATENATES
          # over an existing array); a collection value replaces via
          # `_set_value`.
          remember_merge_block_array(prop) unless collection_value
          prop
        end

        def remember_merge_block_array(prop)
          @merge_block_arrays << prop.object_id
          prop
        end

        def merge_block_array?(prop)
          @merge_block_arrays.include?(prop.object_id)
        end

        # `Property#with` copies lose object identity — call this wherever a
        # marked occurrence is copied before it reaches `merge_reset`.
        def preserve_merge_block_marker(original, copy)
          remember_merge_block_array(copy) if merge_block_array?(original)
          copy
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
          first = self.class.unwrap_parens(args.first)
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
          node = self.class.unwrap_parens(node)
          return true if node.is_a?(Prism::CallNode) && COLLECTION_METHODS.include?(node.name)
          plural_name?(name)
        end

        # Words that look plural but are conceptually singular, so e.g.
        # `json.earnings @summary, partial: ...` types `Earnings`, not
        # `Array<Earnings>`. Apps can extend this via Rails' inflector
        # uncountables (`singularize` consults inflections first), and a
        # `typelize:` pin always overrides the heuristic.
        SINGULAR_LOOKING_PLURALS = %w[news settings earnings analytics statistics series
          metadata data stats credentials].freeze

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

          if kwargs.key?(:collection)
            if @nested
              log_warning(node, "`json.partial!` with `collection:` inside a block is typed as a merged object, " \
                "not an array — use `json.<name> @collection, partial: \"...\", as: ...` or `typelize:`")
            elsif @root_is_array
              # A collection partial in a root-array template CONCATENATES
              # its rendered elements at render — merge its props (widened
              # in `parsed`) instead of dropping them.
              note_root_array_form
            elsif @root_conditional
              # A conditional root collection partial in an OBJECT template —
              # already warned by `warn_on_conditional_root_array`; merging
              # the partial's props into the root object would fabricate a
              # root shape that never renders.
              return []
            end
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
              log_warning(node, "`json.#{node.name}` with a block inside another block is typed as an " \
                "object, not an array — use `typelize:` to pin an array type")
            elsif @root_is_array
              # In a root-array template every form (conditional or not)
              # CONCATENATES at render — its element props merge in (widened
              # in `parsed`) rather than being dropped.
              note_root_array_form
            elsif @root_conditional
              # A conditional root array in an OBJECT template — already
              # warned; its element props describe array ELEMENTS, so walking
              # them into the root object shape would fabricate a root type
              # that never renders.
              return []
            end
            # `array!`/`call` blocks yield each ELEMENT, never the builder.
            warn_shadowed_builder_param(node)
            with_block_scope(node.block, yields_builder: false) { shape_body(node.block) }
          elsif keyword_args(node).key?(:partial)
            handle_array_partial(node, keyword_args(node)[:partial])
          elsif (props = collection_attr_shortcut(positional_args(node)))
            # At the root this is the root array's element shape
            # (`json.array! @people, :id, :name` renders one object per
            # element — see `root_array_call?`); inside a block it can't be
            # expressed on the enclosing key, so warn.
            if @nested
              log_warning(node, "`json.array!` without a block emits its attributes as an object shape, " \
                "not an array — use the block form or `typelize:` to pin an array type")
            elsif @root_is_array
              note_root_array_form
            elsif @root_conditional
              # Same as the block form above: conditional root array in an
              # object template — the attribute shape belongs to elements,
              # not the root object.
              return []
            end
            props
          else
            warn_skipped(node, "`json.#{node.name}` without a block or attribute list")
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
          branch_props = branches.map { |body| with_root_conditional { extract(body, optional: false) } }
          merge_branches(branch_props, fully_covered: fully_covered)
        end

        # Counts root-array-emitting forms in a root-array template: from the
        # second one on, jbuilder CONCATENATES at render, so `parsed` widens
        # every merged element key to optional (see `@root_array_concat`).
        def note_root_array_form
          @root_array_forms = (@root_array_forms || 0) + 1
          @root_array_concat = true if @root_array_forms > 1
        end

        # Marks that the walk is inside a top-level conditional: a root-array
        # form found there was already warned about
        # (`warn_on_conditional_root_array`) and its element props must not
        # leak into the root object shape (see `handle_array_bang`).
        def with_root_conditional
          prev = @root_conditional
          @root_conditional = true unless @nested
          yield
        ensure
          @root_conditional = prev
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
            preserve_merge_block_marker(base, base.with(optional: optional, nullable: widened_nullable(base, present)))
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

        # `multi` guard: an array of nulls (`typelize: "null[]"`) is not the
        # `null` literal.
        def null_type?(prop)
          (prop.type.is_a?(String) || prop.type.is_a?(Symbol)) && prop.type.to_s == "null" && !prop.multi
        end

        # With an inferable (AR) model the type stays nil so model inference
        # resolves it (nested shapes only infer nil-typed props, so a premature
        # hint would block the column type). Without a model, name hints are
        # the best signal.
        def property_from_column(col, optional: false)
          build_property(col, type: @column_inference ? nil : name_hint(col), optional: optional)
        end

        def build_property(name, type: nil, optional: false, nullable: false, multi: false, additional_types: nil, user_asserted: false, inference_locked: false)
          Property.new(
            name: name,
            type: type,
            optional: optional,
            nullable: nullable,
            multi: multi,
            column_name: name,
            additional_types: additional_types,
            user_asserted: user_asserted,
            inference_locked: inference_locked
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

        # Lexical builder-name scopes, kept as a stack of frames. A frame
        # either ALIASES a local name to the builder (object/child! blocks —
        # jbuilder yields self) or SHADOWS a name (element-yielding array
        # blocks — the param is the collection element, not the builder). The
        # innermost frame for a name wins, so an inner array block whose
        # param reuses an outer alias correctly hides it. See `json_call?`.
        def with_block_scope(block_node, yields_builder:)
          frames = block_scope_frames(block_node, yields_builder: yields_builder)
          stack = (@json_aliases ||= [])
          frames.each { |frame| stack.push(frame) }
          yield
        ensure
          frames.size.times { stack.pop }
        end

        def block_scope_frames(block_node, yields_builder:)
          kind = yields_builder ? :alias : :shadow
          if (param = block_builder_alias(block_node))
            [{name: param, kind: kind}]
          elsif block_node.is_a?(Prism::BlockNode) && implicit_params?(block_node.parameters)
            # No named parameters: `it`/`_1` refer to the yielded value — the
            # builder in object blocks, the element in array blocks. (Prism
            # represents their use as ItParametersNode/NumberedParametersNode.)
            [{name: :it, kind: kind}, {name: :_1, kind: kind}]
          else
            []
          end
        end

        def implicit_params?(params)
          params.nil? ||
            (defined?(Prism::ItParametersNode) && params.is_a?(Prism::ItParametersNode)) ||
            params.is_a?(Prism::NumberedParametersNode)
        end

        # An element-yielding block whose parameter reuses the builder's name
        # (or an active alias) rebinds it to the ELEMENT. Only writing
        # THROUGH that name as if it were the builder (`a.title "x"`,
        # `a.items do ... end`) misleads — those properties are set on the
        # element and never rendered. Read-only uses (`json.title a`,
        # `json.x a.title`) are legitimate element access and must not warn:
        # a false positive here fails strict builds on correct code.
        def warn_shadowed_builder_param(node)
          param = block_builder_alias(node.block)
          return if param.nil?
          return unless param == :json || json_alias?(param)
          return unless builder_write_through?(node.block.body, param)

          log_warning(node, "the block parameter `#{param}` shadows the JSON builder inside this " \
            "collection block (jbuilder yields the collection element here) — properties set " \
            "on it are not rendered; rename the parameter")
        end

        # Method names that READ from the yielded element rather than writing
        # a JSON key through it: hash/attribute access and common Enumerable
        # readers. A genuine json-write through a shadowing param is a
        # set!-style call with a made-up key name (`j.title "x"`) — never one
        # of these.
        SHADOW_READER_CALLS = %i[[] fetch dig each map sum count size length first last].freeze
        private_constant :SHADOW_READER_CALLS

        # A set!-style call through `name`: a method call whose receiver is
        # the shadowing local and that passes a value or block. Known reader
        # calls (`j[:amount]`, `j.fetch(:x)`) are element ACCESS, not writes —
        # counting them would warn on templates that render correctly, which
        # fails strict builds on a false positive.
        def builder_write_through?(node, name)
          return false if node.nil?

          if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::LocalVariableReadNode) &&
              node.receiver.name == name && !SHADOW_READER_CALLS.include?(node.name) &&
              (node.arguments&.arguments&.any? || node.block)
            return true
          end
          node.compact_child_nodes.any? { |child| builder_write_through?(child, name) }
        end

        # The block parameter jbuilder binds the yielded value to; nil when
        # the block takes no simple positional parameter.
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

        # Merge-time warnings fold multiple statements, so there is no single
        # source node to cite — the template path alone locates the problem.
        def warn_merge(message)
          Typelizer.logger.warn("Typelizer::Jbuilder: #{@path}: #{message}")
        end

        # Value-level inference: the type, whether it came from a source-code
        # literal (`locked` — a same-named model column must not override
        # what the template demonstrably renders), and whether a conditional
        # arm contributes `null`.
        def infer_value(node, name:)
          node = self.class.unwrap_parens(node)
          return {type: "null", nullable: false, locked: true} if node.is_a?(Prism::NilNode)
          if TYPE_BY_LITERAL.key?(node.class)
            return {type: TYPE_BY_LITERAL[node.class], nullable: false, locked: true}
          end
          return {type: "string", nullable: false, locked: true} if time_call?(node)
          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            return infer_conditional_value(node, name: name)
          end
          # `a && b` renders b only when a is truthy; a nil left side leaks
          # through as the value, so the right side's type widens by `| null`.
          if node.is_a?(Prism::AndNode)
            right = infer_value(node.right, name: name)
            return {type: right[:type], nullable: true, locked: right[:locked]}
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
            return {type: guess_from_name(name), nullable: false, locked: false}
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

        def guess_from_name(name)
          name_hint(name) || "unknown"
        end

        def name_hint(name)
          NAME_HINT.each { |pat, t| return t if name.to_s.match?(pat) }
          nil
        end

        # A `json.<name> ...` call. The receiver is normally the bare `json`
        # method; inside an object block jbuilder yields the builder itself,
        # so a block param (`do |json| ...`), `it`, or `_1` rebinds it — a
        # read of a name whose innermost scope frame is an ALIAS counts too.
        def json_call?(node)
          return false unless node.is_a?(Prism::CallNode)

          receiver = node.receiver
          case receiver
          when Prism::CallNode
            (receiver.name == :json && receiver.receiver.nil?) ||
              # Older prism grammars parse a parameterless block's `it` as a
              # bare method call rather than ItLocalVariableReadNode.
              (receiver.name == :it && receiver.receiver.nil? && receiver.arguments.nil? && json_alias?(:it))
          when Prism::LocalVariableReadNode
            json_alias?(receiver.name)
          else
            it_receiver?(receiver) && json_alias?(:it)
          end
        end

        def it_receiver?(node)
          defined?(Prism::ItLocalVariableReadNode) && node.is_a?(Prism::ItLocalVariableReadNode)
        end

        def json_alias?(name)
          frame = @json_aliases&.reverse_each&.find { |f| f[:name] == name }
          !!frame && frame[:kind] == :alias
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
            unwrapped = self.class.unwrap_parens(node)
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
