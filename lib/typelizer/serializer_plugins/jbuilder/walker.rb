# frozen_string_literal: true

require "digest"
require "set"

# Walker collaborators live in walker/ and are loaded only from here, so
# they stay behind the same lazy `activate_walker!` gate (and compile after
# Coverage.start under the fuzz coverage ratchet).
require_relative "walker/array_of"
require_relative "walker/deferred_inference"
require_relative "walker/ast_helpers"
require_relative "walker/inertia_directives"
require_relative "walker/typelize_override"
require_relative "walker/value_inference"
require_relative "walker/property_folder"

# Loaded lazily via `Jbuilder.activate_walker!`, never on the eager require
# chain: all `Prism::*` references live here so `require "typelizer"` stays
# safe without the prism gem (or with Ruby's bundled prism < 1.0).
module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        include AstHelpers
        extend AstHelpers
        include InertiaDirectives
        include TypelizeOverride
        include ValueInference

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

        # Every type-distorting jbuilder API method warns through the logger
        # rather than being skipped silently (see the `extract_one` dispatch);
        # jbuilder_api_canary_spec guards that the dispatch stays exhaustive.
        PASSTHROUGH_CALLS = %i[cache! cache_if! cache_root!].freeze

        # json.* calls that never write a key into the current scope — a
        # block containing only these still renders BLANK (see
        # `block_can_render_blank?`).
        NON_WRITING_CALLS = %i[key_format! ignore_nil! deep_format_keys! attributes! target!].freeze
        private_constant :NON_WRITING_CALLS

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
          folder.merge_same_level(stmts.flat_map { |n| extract_one(n, optional: optional) }.compact)
        end

        # The same-level/cross-branch fold collaborator. The fold is free of
        # walk-order state but needs the template path (warnings), the
        # merged-partial finalizer, and the walk-cycle registry — all owned
        # here, injected once.
        def folder
          @folder ||= PropertyFolder.new(
            path: @path,
            finalizer: method(:finalize_merged_property),
            in_progress: ->(template_path) { self.class.walks_in_progress.include?(template_path) }
          )
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

          value = unwrap_parens(args.first)
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
              # A valueless object block whose scope renders BLANK is OMITTED
              # at render (`_merge_block` returns BLANK, `_set_value` skips
              # blank values) — verified: `json.k do json.x @a if @c end`
              # with the condition false renders `{}` with no `k` key, and
              # the omission cascades through enclosing blocks.
              # Collection-value blocks are exempt: they render `[]`,
              # keeping the key. Checked inside the block scope so rebound
              # builder params (`do |j| j.x 1 end`) count as writes.
              optional ||= !multi && block_can_render_blank?(node.block)
              children, non_children = partition_child_bangs(node.block)
              if children.any?
                next handle_child_array(node, name: name, optional: optional, children: children,
                  rest: non_children, collection_value: multi)
              end

              interfaces, rest = partition_composed_partials(node.block, prop_name: name)
              if interfaces.any?
                additional = interfaces.drop(1)
                rest_props = with_nested { extract(rest, optional: false) }
                # An intersection is only truthful while no key is claimed by
                # two members: at render a later same-key write REPLACES, but
                # `A & {k: T2}` still asserts A's `k: T1` (T1 & T2 can be
                # `never`). Any cross-member collision demotes the block to a
                # plain inline-merged Shape — the same statement-order fold
                # (last-wins / conditional union) used for root-level merges.
                # A member whose OWN walk is still on the stack (a recursive
                # partial — e.g. `_metadata` composing itself under a key)
                # cannot enumerate its keys yet: forcing `properties` here
                # recurses to SystemStackError. Skip it in the scan and keep
                # the named recursive reference (TS supports those).
                member_keys = interfaces.map do |i|
                  next [] if folder.walk_in_progress?(i)
                  i.properties.map { |p| p.name.to_s }
                end
                member_keys << rest_props.map { |p| p.name.to_s }
                flat_keys = member_keys.flatten
                if flat_keys.uniq.size == flat_keys.size
                  additional += [Shape.new(properties: rest_props)] if rest_props.any?
                  next build_property(name, type: interfaces.first, additional_types: additional, optional: optional, multi: multi)
                end
              end
              build_property(name, type: Shape.new(properties: shape_body(node.block)), optional: optional, multi: multi)
            end
          end
        end

        # True when no statement in the block body is guaranteed to write a
        # key — jbuilder then renders the scope BLANK and the enclosing key
        # is omitted, so the property must be optional.
        def block_can_render_blank?(block_node)
          return true unless block_node.is_a?(Prism::BlockNode)

          (block_node.body&.body || []).none? { |stmt| definitely_writes?(stmt) }
        end

        # Whether a statement is guaranteed to write into the current scope
        # at render:
        # - a conditional writes only when the chain is fully covered AND
        #   every branch writes (matches renders: `if/else` both writing
        #   always produces the key; a lone `if` can skip it)
        # - a valueless named block writes only what its own body writes
        #   (blank bodies are omitted — the cascade case), and cache
        #   wrappers are transparent
        # - values, `extract!`, `array!`/`child!` (arrays render `[]` even
        #   when empty), `merge!`, and `partial!` write unconditionally
        # - non-json statements never write
        def definitely_writes?(node)
          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            branches, fully_covered = collect_branches(node)
            return fully_covered && branches.all? { |body| body.any? { |stmt| definitely_writes?(stmt) } }
          end
          return false unless json_call?(node)
          return false if NON_WRITING_CALLS.include?(node.name)

          if PASSTHROUGH_CALLS.include?(node.name)
            return node.block.is_a?(Prism::BlockNode) &&
                with_block_scope(node.block, yields_builder: true) { !block_can_render_blank?(node.block) }
          end

          if node.block.is_a?(Prism::BlockNode) && block_value_args(node).empty? &&
              !%i[array! child! call].include?(node.name)
            # Recurse with the nested block's builder alias in scope so
            # `json.b do |b| b.x 1 end` counts its write.
            return with_block_scope(node.block, yields_builder: true) { !block_can_render_blank?(node.block) }
          end
          true
        end

        # Positional VALUE arguments of a block-bearing call — `set!`'s
        # leading literal key is not a value.
        def block_value_args(node)
          args = positional_args(node)
          (node.name == :set!) ? args.drop(1) : args
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
          merged = folder.merge_branches(branch_props, fully_covered: true)
          element = Shape.new(properties: merged)
          # A collection VALUE (`json.comments @comments do |c| json.child! …`)
          # renders one scope per element, and `child!` turns EACH scope into
          # an array — array of arrays at runtime, `Array<Array<…>>` here.
          element = ArrayOf.new(element) if collection_value
          prop = build_property(name, type: element, optional: optional, multi: true)
          # Only the valueless form is `_merge_block`-ed (and so CONCATENATES
          # over an existing array); a collection value replaces via
          # `_set_value`. The marker is a Property field, so it rides through
          # every `#with` copy (including across a `json.partial!` merge into
          # another walker) without out-of-band bookkeeping.
          prop = prop.with(merge_block_array: true) unless collection_value
          prop
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
          first = unwrap_parens(args.first)
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

          # The partial's properties are the FINAL output of its own
          # interface — already inferred against the PARTIAL's model. Deep-copy
          # them (they are shared, memoized objects — host inference mutates in
          # place, which would corrupt the partial's own interface and make
          # output order-dependent) and mark them resolved so the host's model
          # inference and metadata can't repaint them against the HOST's model.
          @context.interface_for(partial_class).properties.map { |prop| finalize_merged_property(prop) }
        end

        # Deep-copies a merged partial property and flags it (recursively)
        # `inference_locked`, so the host interface treats it as final: no
        # shared-object mutation, no model/metadata repaint against the host.
        def finalize_merged_property(prop)
          copy = prop.with(inference_locked: true, type: finalize_merged_type(prop.type))
          if copy.additional_types&.any?
            copy = copy.with(additional_types: copy.additional_types.map { |t| finalize_merged_type(t) })
          end
          copy
        end

        # Deep-copies inline shapes reachable from a merged type (own Shape,
        # union members, ArrayOf elements), recursing through
        # `finalize_merged_property`. Named Interface references and plain type
        # strings are shared as-is — they are separate, immutable interfaces.
        def finalize_merged_type(type)
          case type
          when Shape then Shape.new(properties: type.properties.map { |p| finalize_merged_property(p) })
          when Array then type.map { |member| finalize_merged_type(member) }
          else
            if type.respond_to?(:map_element_shape)
              type.map_element_shape { |shape| finalize_merged_type(shape) }
            else
              type
            end
          end
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
          folder.merge_branches(branch_props, fully_covered: fully_covered)
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
      end
    end
  end
end
