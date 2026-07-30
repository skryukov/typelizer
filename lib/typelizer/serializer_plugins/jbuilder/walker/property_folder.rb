# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # The merge/fold semantics of same-name properties — jbuilder's
        # runtime re-set rules (last-wins replace, object deep-merge, array
        # concat, conditional union) plus the cross-branch merge, expressed
        # over Property values. One folder per walker instance: it carries
        # the recursive-flatten guard (`@flattening_interfaces`) across a
        # fold and warns with the host template's path.
        #
        # The fold is independent of walk-order state (scopes, nesting,
        # root-array bookkeeping) but needs three things only the walker
        # owns, injected at construction:
        #
        # - `path`: the template path merge warnings cite
        # - `finalizer`: deep-copies + inference-locks a merged partial
        #   property (`Walker#finalize_merged_property`) when an interface
        #   flattens into the host's fold
        # - `in_progress`: the walk-cycle registry predicate ("is this
        #   template's walk on the stack?") that keeps recursive partial
        #   references from being flattened into infinite unrolls
        class PropertyFolder
          def initialize(path:, finalizer:, in_progress:)
            @path = path
            @finalizer = finalizer
            @in_progress = in_progress
            # RECURSIVE interfaces cannot be flattened repeatedly: inlining
            # one produces a fresh copy that still contains the self-member,
            # so two recursive compositions folding on the same key would
            # unroll each other forever. Tracks the interfaces being
            # flattened across the current fold (see `merge_reset`).
            @flattening_interfaces = Set.new
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

          # Merges same-name props across branches: only ONE branch runs at
          # render, so disagreeing branch types UNION (`json.k 20` vs
          # `json.k @dynamic` renders either) — through the same member
          # machinery as the sequential fold, so delegated (nil-typed) members
          # resolve via model inference and `unknown` members keep the
          # post-inference warning alive instead of being silently swallowed
          # by another branch's type. Nullability widens (a bare `nil` branch
          # contributes `| null`, not a member); a prop is optional unless
          # every branch of a fully-covered chain emits it (or any branch
          # marked it optional). A `typelize:` assertion in any branch wins
          # outright and carries `user_asserted` through so model inference
          # can't clobber it.
          def merge_branches(branch_props, fully_covered:)
            indexed = branch_props.map { |props| props.to_h { |p| [p.name.to_s, p] } }
            names = branch_props.flat_map { |props| props.map { |p| p.name.to_s } }.uniq
            names.map do |name|
              occurrences = indexed.map { |idx| idx[name] }
              present = occurrences.compact
              base = merged_branch_occurrence(present)
              optional = present.any?(&:optional) || !(fully_covered && occurrences.all?)
              base.with(optional: optional, nullable: widened_nullable(base, present))
            end
          end

          # Whether an interface-like member's template walk is currently on
          # the stack (a recursive partial reference). Public: the walker's
          # composed-partial key scan needs the same question answered.
          def walk_in_progress?(member)
            member.respond_to?(:serializer) &&
              member.serializer.respond_to?(:_template_path) &&
              @in_progress.call(member.serializer._template_path)
          end

          private

          # One re-set step: `acc` is what accumulated so far, `incoming` the
          # next same-name write in statement order. Each occurrence is folded
          # as its FULL rendered type — type + multi + nullable +
          # optional (≙ conditional) + user_asserted — mirroring what jbuilder
          # does with the rendered VALUE at runtime: an unconditional write is
          # `_set_value` (replace) or `_merge_block` (object deep-merge); a
          # conditional write forks the runtime into ran/didn't-run, i.e. a
          # union of the folded result with the accumulator.
          def merge_reset(acc, incoming)
            flattened = nil
            if composed_object_block_pair?(acc, incoming)
              # jbuilder DEEP-MERGES consecutive object blocks (`_merge_block`
              # → `_merge_values(Hash, Hash)`), but a composed side (named
              # interface / intersection) has no faithful deep-merge
              # representation — replacing or unioning it would reject merged
              # renders. Flatten to Shapes so the shape_pair? branches fold it;
              # re-entry on a recursive interface degrades to `unknown` (see
              # `@flattening_interfaces`).
              keys = (composed_interface_members(acc) + composed_interface_members(incoming))
                .map { |i| flatten_identity(i) }
              if keys.any? { |key| @flattening_interfaces.include?(key) }
                warn_merge("`#{acc.name}` deep-merges a recursive partial composition; the unrolled " \
                  "type is not statically expressible — emitted `unknown`; use `typelize:` to pin the type")
                return unknown_property(acc.name, optional: acc.optional && incoming.optional)
              end
              flattened = keys
              keys.each { |key| @flattening_interfaces.add(key) }
              acc = flatten_composed(acc)
              incoming = flatten_composed(incoming)
            end

            if merge_block_concat?(acc, incoming)
              # A valueless `json.<key> do json.child! ... end` block over an
              # array-valued key goes through jbuilder's `_merge_block`, whose
              # Array+Array branch CONCATENATES — elements of BOTH shapes occur.
              # A composed (intersection) accumulator flattens first: the fold
              # wraps `acc.type` alone into the element union while `#with`
              # would carry `additional_types` onto the merged prop, where TS
              # precedence binds it to the LAST union member only.
              concat_merge(flatten_intersection(acc), incoming, conditional: incoming.optional)
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
              unknown_property(acc.name, optional: acc.optional)
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
          ensure
            flattened&.each { |key| @flattening_interfaces.delete(key) }
          end

          def composed_interface_members(prop)
            [*Array(prop.type), *Array(prop.additional_types)].select { |m| interface_like?(m) }
          end

          def flatten_identity(member)
            serializer = member.respond_to?(:serializer) ? member.serializer : nil
            if serializer.respond_to?(:_template_path)
              serializer._template_path
            else
              member
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
              return unknown_property(acc.name, optional: acc.optional)
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

          # A composed (intersection) prop entering a union/concat fold has no
          # faithful per-member representation (`&` binds tighter than `|`, so
          # it would attach to a single union member). Intersection members
          # have pairwise-disjoint keys — a collision demotes the block at
          # composition time — so the intersection flattens LOSSLESSLY into one
          # Shape; interface-owned properties are deep-copied (the finalizer)
          # so the host fold can't corrupt the partial's own interface.
          def flatten_intersection(prop)
            additionals = Array(prop.additional_types)
            return prop if additionals.empty?

            members = [*Array(prop.type), *additionals]
            return prop unless members.all? { |m| m.is_a?(Shape) || interface_like?(m) }
            # A recursive (in-progress) member can't be flattened — reading its
            # properties would re-enter its own walk. Keep the composed form.
            return prop if members.any? { |m| interface_like?(m) && walk_in_progress?(m) }

            props = members.flat_map do |m|
              m.is_a?(Shape) ? m.properties : m.properties.map { |p| @finalizer.call(p) }
            end
            prop.with(type: Shape.new(properties: props), additional_types: nil)
          end

          # Two same-key object blocks where at least one is composed: both
          # must become plain Shapes before the deep-merge fold.
          def composed_object_block_pair?(a, b)
            [a, b].all? { |p| !p.multi && (p.type.is_a?(Shape) || interface_like?(p.type)) } &&
              [a, b].any? { |p| interface_like?(p.type) || Array(p.additional_types).any? }
          end

          def flatten_composed(prop)
            return flatten_intersection(prop) if Array(prop.additional_types).any?
            return prop unless interface_like?(prop.type)
            return prop if walk_in_progress?(prop.type)

            props = prop.type.properties.map { |p| @finalizer.call(p) }
            prop.with(type: Shape.new(properties: props))
          end

          # jbuilder concatenates only when the INCOMING write is a valueless
          # `child!` block (`_merge_block` → `_merge_values(Array, Array)`) and
          # the key currently holds an array — either a plain array occurrence
          # (`multi`) or a union with array members. Collection-VALUE blocks
          # replace instead (`_set` → `_set_value`), so they never take this
          # path.
          def merge_block_concat?(acc, incoming)
            !!incoming.merge_block_array &&
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

          # Element types contributed by one array-valued occurrence. An
          # ArrayOf member (a branch-merged `child!` array, whose union holds
          # `Array<{b}> | Array<{c}>`) is UNWRAPPED to its element shapes, so a
          # concat folds to `Array<{a} | {b} | {c}>` — never a nested
          # `Array<Array<…>>`.
          def element_members(prop)
            members = Array(prop.type).flat_map do |member|
              member.is_a?(ArrayOf) ? arrayof_members(member) : [member]
            end
            members.empty? ? ["unknown"] : members
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
              h[p.name.to_s] = earlier_optional ? p.with(optional: true) : p
            end
            later.properties.each do |prop|
              key = prop.name.to_s
              prop = prop.with(optional: true) if incoming_optional
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

          # The single property a set of branch occurrences merges into: an
          # asserted occurrence wins outright; a sole typed occurrence stands
          # as-is (bare-`nil` branches contribute nullability only); multiple
          # typed occurrences union their members.
          def merged_branch_occurrence(present)
            asserted = present.find(&:user_asserted)
            return asserted if asserted

            typed = present.reject { |p| null_type?(p) }
            base = typed.first || present.first
            return base if typed.size <= 1

            members = typed.flat_map { |p| union_members(p) }.uniq
            type, multi = fold_members(members)
            delegated = typed.any? { |p| !p.multi && p.type.nil? }
            base.with(
              type: type,
              multi: multi,
              inference_locked: !delegated && typed.any?(&:inference_locked)
            )
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

          # The degrade path: a fold with no faithful static rendering emits a
          # fresh `unknown` property. Deliberately NOT `#with` — that would
          # carry multi/additional_types/assertions from the degraded
          # occurrence onto a type that no longer means any of them. Field
          # defaults mirror `Walker#build_property`.
          def unknown_property(name, optional:)
            Property.new(name: name, type: "unknown", optional: optional,
              nullable: false, multi: false, column_name: name)
          end

          # Merge-time warnings fold multiple statements, so there is no single
          # source node to cite — the template path alone locates the problem.
          def warn_merge(message)
            Typelizer.logger.warn("Typelizer::Jbuilder: #{@path}: #{message}")
          end
        end
      end
    end
  end
end
