# frozen_string_literal: true

require_relative "error"
# camelize/singularize/demodulize/safe_constantize — needed by name
# derivation (and the walker's pluralization heuristic) in non-Rails
# processes where nothing else has loaded the core extensions yet.
require "active_support/core_ext/string/inflections"

module Typelizer
  module Jbuilder
    # Two templates claiming the same type name (via `typelize_as` or
    # path-derived naming). Raised only during a generation cycle, never at boot.
    class NameCollision < Error; end

    module Templates; end

    # Runtime no-op helpers so templates can declare `typelize_as "Foo"` /
    # `typelize_from User` at the top. The plugin reads these statically via
    # Prism; at render time they do nothing. Auto-included via the railtie.
    module TemplateHelpers
      def typelize_as(_name)
      end

      def typelize_from(_model)
      end
    end

    # Inline `json.foo value, typelize: "string"` annotations are read by the
    # AST walker, but at render time jbuilder's `set!` has no `**kwargs`, so
    # Ruby 3 packs them as a positional Hash and `_extract_method_values`
    # raises. This module strips typelizer-reserved kwargs before forwarding to
    # upstream `set!`. Prepended onto `JbuilderTemplate` via the railtie
    # whenever jbuilder is loaded — independent of whether the plugin is
    # enabled — so annotated templates never crash a render.
    #
    # Stripping only ever touches kwargs that accompany a real positional
    # value or block — `typelize:`/`inertia:` in those positions are reserved
    # annotation grammar. The only non-annotation pattern affected is a
    # braceless hash containing those exact keys passed WITH a block
    # (pathological; documented in the guide). A braceless hash with NO
    # value and no block (`json.settings theme: "dark"`) is jbuilder's plain
    # nested-object form: it's re-packed as the positional value untouched,
    # even when a key happens to be named `typelize` or `inertia`.
    #
    # Each gem strips its own render-inert vocabulary (`typelize:`); the
    # render-ACTIVE `inertia:` kwarg (owned by jbuilder-inertia) is stripped
    # only when that gem's patch is absent from the template's ancestry.
    #
    # The `method_missing` override defeats jbuilder's
    # `alias_method :method_missing, :set!` quirk (the alias captures the
    # original `set!`, bypassing any prepended `set!`).
    module SetExt
      RESERVED_KWARGS = %i[typelize].freeze

      # Render-ACTIVE kwargs owned by other gems' template patches, mapped to
      # their owner (matched by NAME so typelizer never loads those gems). A
      # foreign kwarg is stripped only when its owner patch is absent.
      FOREIGN_KWARGS = {
        inertia: {owner: "JbuilderInertia::JbuilderExt", gem: "jbuilder-inertia"}.freeze
      }.freeze

      class << self
        # Lazy (at strip time — `on_load` ordering between the gems isn't ours
        # to control) and one-way memoized per owner: once seen the patch can't
        # be removed, but while absent we re-check each strip so a late prepend
        # is picked up next render. The const-defined check short-circuits the
        # common "gem not loaded" case.
        #
        # `Jbuilder < BasicObject`, so `template.class` would dispatch into
        # `set!`; bind `Object#class` explicitly.
        def foreign_runtime_present?(kwarg, template)
          memo = (@foreign_runtime_present ||= {})
          return true if memo[kwarg]

          owner_name = FOREIGN_KWARGS.fetch(kwarg)[:owner]
          return false unless ::Object.const_defined?(owner_name)

          klass = ::Object.instance_method(:class).bind_call(template)
          present = klass.ancestors.any? { |mod| mod.name == owner_name }
          memo[kwarg] = true if present
          present
        end

        def warn_foreign_stripped!(kwarg)
          warned = (@foreign_strip_warned ||= {})
          return if warned[kwarg]

          warned[kwarg] = true
          Typelizer.logger.warn(
            "Typelizer: `#{kwarg}:` option found but #{FOREIGN_KWARGS.fetch(kwarg)[:gem]} " \
            "is not installed; option ignored"
          )
        end
      end

      def method_missing(name, *args, **kwargs, &block)
        set!(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        super
      end

      # jbuilder keeps `method_missing` private (`private :method_missing`
      # after aliasing it to `set!`); redefining it public here would leak it
      # into `public_instance_methods` and make `json.method_missing(...)`
      # publicly callable — keep upstream's visibility.
      private :method_missing, :respond_to_missing?

      def set!(name, *args, **kwargs, &block)
        # Hot path: a bare `json.foo value` carries no kwargs at all — skip
        # straight to upstream `set!` (this runs once per json.* call).
        return super(name, *args, &block) if kwargs.empty?

        # A braceless trailing hash with NO accompanying value or block is not
        # an annotation — it IS the value (`json.settings theme: "dark"`),
        # which plain jbuilder (no `**kwargs` anywhere) receives positionally
        # and renders as a nested object. Annotations only ride along with a
        # real value or block, so re-pack the hash as the positional value
        # untouched: stripping here would silently corrupt domain fields that
        # happen to be named `typelize`/`inertia`. Exception: when a foreign
        # owner's patch is live and claims a key, forward as kwargs so the
        # owner decides.
        if args.empty? && block.nil?
          return super(name, kwargs) unless _typelizer_foreign_claims?(kwargs)
        end

        _typelizer_strip_kwargs!(kwargs)

        # Bare `super` re-forwards the CURRENT parameter values — i.e. the
        # stripped kwargs — and an emptied `**kwargs` splats to nothing
        # (guaranteed since Ruby 3.0's keyword separation), so upstream `set!`
        # — which has no `**kwargs` — never sees a positional {}; surviving
        # kwargs reach the next prepend in the chain as real kwargs. Every
        # emitter below forwards through this same strip-then-`super` tail.
        super
      end

      # The non-`set!` emitters need the same protection: jbuilder's
      # `extract!`/`array!`/`call` declare no `**kwargs`, so a `typelize:`
      # annotation would pack into the positional list and crash. Same
      # sole-hash re-pack and strip-then-splat rules as `set!`. (The
      # walker ignores `typelize:` here — it has no per-field meaning on
      # these.) `*args` instead of upstream's `(object, *attributes)` so a
      # vanilla sole-hash call (`json.extract!(a: 1)` — the hash is the
      # object) doesn't raise ArgumentError after Ruby splits it into kwargs.
      def extract!(*args, **kwargs)
        return super(*args) if kwargs.empty?
        return super(kwargs) if args.empty?

        _typelizer_strip_kwargs!(kwargs)
        super
      end

      def array!(*args, **kwargs, &block)
        return super(*args, &block) if kwargs.empty?
        return super(kwargs) if args.empty? && block.nil?

        _typelizer_strip_kwargs!(kwargs)
        super
      end

      def call(*args, **kwargs, &block)
        return super(*args, &block) if kwargs.empty?
        return super(kwargs) if args.empty? && block.nil?

        _typelizer_strip_kwargs!(kwargs)

        # Stripping can leave a block-only call (`json.(typelize: "T") { }` —
        # a block is guaranteed here, the blockless sole-hash form returned
        # above). Upstream `call(object, *attributes)` has no default for
        # `object` (unlike `array!`), so forward an empty collection: renders
        # `[]`, mirroring the stripped `array!` form.
        return super([], &block) if kwargs.empty? && args.empty?

        super
      end

      # `merge!(object)` takes exactly one positional and no `**kwargs`, so a
      # `typelize:` annotation packs as a second positional and raises
      # ArgumentError. Strip our vocabulary; a braceless sole hash IS the
      # object being merged (`json.merge!(a: 1)`), so it's re-packed untouched
      # unless a live foreign owner claims a key. The walker can't type a
      # dynamic merge and already warns on it, so nothing is lost here.
      def merge!(*args, **kwargs)
        return super(*args) if kwargs.empty?
        if args.empty?
          return super(kwargs) unless _typelizer_foreign_claims?(kwargs)
        end

        _typelizer_strip_kwargs!(kwargs)
        super
      end

      # `child!` appends the current block's object to the target array; it
      # takes no positional value and no `**kwargs`, so a `typelize:`
      # annotation packs positionally and raises. Strip it and forward the
      # block untouched.
      def child!(*args, **kwargs, &block)
        return super(*args, &block) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)
        super
      end

      # jbuilder's `partial!` has no `**kwargs`, so a `typelize:` annotation
      # (or a foreign `inertia:` when its gem is absent) survives into the
      # partial's locals hash and reaches the template as an unexpected local
      # — a 500 under Rails strict locals. Strip our vocabulary before
      # forwarding; the walker ignores `typelize:` on `partial!` (a merged
      # partial can't be typed through a per-call annotation). Keyword-style
      # locals that survive stripping re-pack as jbuilder's trailing options
      # hash; a braces-hash locals argument arrives positionally and skips
      # this path entirely via the empty-kwargs fast path.
      def partial!(*args, **kwargs, &block)
        return super(*args, &block) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)
        super
      end

      private

      # True when a live foreign patch (e.g. jbuilder-inertia's) owns one of
      # the hash's keys — the sole-hash re-pack must not hide the kwargs from
      # the owner further down the prepend chain.
      def _typelizer_foreign_claims?(kwargs)
        FOREIGN_KWARGS.each_key.any? do |kwarg|
          kwargs.key?(kwarg) && SetExt.foreign_runtime_present?(kwarg, self)
        end
      end

      # Strip before any other logic so behavior is identical under either
      # gem's prepend order.
      def _typelizer_strip_kwargs!(kwargs)
        FOREIGN_KWARGS.each_key do |kwarg|
          next unless kwargs.key?(kwarg)
          next if SetExt.foreign_runtime_present?(kwarg, self)

          kwargs.delete(kwarg)
          SetExt.warn_foreign_stripped!(kwarg)
        end
        RESERVED_KWARGS.each { |k| kwargs.delete(k) }
        kwargs
      end
    end

    class << self
      # Whether the plugin does automatic work (discovery, parsing, prism).
      # Auto-detected from `config.jbuilder_views` being present, with
      # `config.jbuilder_enabled` as an explicit override. Gates ONLY
      # discovery — render-safety patches install regardless (see railtie).
      def enabled?
        override = Typelizer.configuration.jbuilder_enabled
        return override unless override.nil?

        Array(Typelizer.configuration.jbuilder_views).any?
      end

      def template(path, views_root: default_views_root, model: nil, as: nil)
        # Normalize once at entry (mirrors `discover` and the listener): a
        # relative or Pathname root would double-prefix glob results.
        views_root = File.expand_path(views_root.to_s)
        track_views_root(views_root)
        full_path = File.expand_path(path, views_root)
        type_name = as ? validate_type_name!(as.to_s, full_path) : derive_type_name(full_path, views_root)
        check_name_collision!(type_name, full_path)

        previous = registry[full_path]
        klass = ensure_class(type_name)
        klass.define_singleton_method(:_template_path) { full_path }
        klass.define_singleton_method(:_views_root) { views_root }
        # Routes column/enum/comment inference through the model-plugin
        # pipeline. Stored by NAME and constantized lazily each generation so a
        # Zeitwerk reload always resolves the freshly loaded class (a captured
        # class would go stale with pre-reload columns).
        model_name = model.is_a?(Class) ? model.name : model&.to_s
        if model_name
          klass.define_singleton_method(:_typelizer_model_name) { model_name.safe_constantize }
        elsif model
          # Anonymous class — no name to re-resolve; keep the object.
          klass.define_singleton_method(:_typelizer_model_name) { model }
        end

        klass.typelizer_config do |c|
          c.serializer_plugin = SerializerPlugins::Jbuilder
          c.serializer_name_mapper = ->(s) { s.name.demodulize }
        end

        registry[full_path] = klass
        if (rel = relative_key(full_path, views_root))
          # First registration wins the relative slot (Rails view-path order).
          relative_registry[rel] = klass if relative_registry[rel].nil? || relative_registry[rel].equal?(previous)
        end
        # Re-registering the same template under a new name (explicit `as:`
        # rename between `template` calls) must not leave the old constant
        # generating a stale type.
        remove_registration(previous) if previous && !previous.equal?(klass)
        klass
      end

      # Templates own their type-name/model bindings via top-of-file DSL
      # (`typelize_as`, `typelize_from`). `discover` reads them from the
      # Walker's cached parse, which is reused for the property walk.
      def discover(views_root = default_views_root, model_resolver: nil)
        # Same entry normalization as `template`. The root is tracked even when
        # empty so a partial added there mid-cycle stays reachable via fallback.
        views_root = File.expand_path(views_root.to_s)
        track_views_root(views_root)
        walker = SerializerPlugins::Jbuilder.activate_walker!
        # Sorted for deterministic registration order — stable `index.ts`
        # output and stable collision error messages across filesystems.
        # `base:` keeps the root out of the glob PATTERN so a real checkout
        # path containing glob metacharacters (`app [wip]/`) still matches
        # its templates instead of silently discovering nothing.
        Dir.glob("**/*.json.jbuilder", base: views_root).sort.each do |rel_path|
          path = File.join(views_root, rel_path)
          # Rails view-path shadowing: a template at the same relative path
          # as one from an earlier root is overridden by it at render time —
          # the earlier registration wins, this file is skipped (it is not a
          # name collision).
          rel = relative_key(path, views_root)
          if rel && (winner = relative_registry[rel]) && winner._template_path != path
            Typelizer.logger.debug(
              "Typelizer::Jbuilder: #{path} is shadowed by #{winner._template_path} (view-path order); skipping"
            )
            next
          end

          metadata = walker.metadata_for(path)
          model = metadata[:model] || model_resolver&.call(path)
          begin
            template(path, views_root: views_root, model: model, as: metadata[:type_name])
          rescue NameCollision => e
            # One ambiguous pair must not kill discovery for the whole tree:
            # skip this file (its partial references degrade to `unknown`
            # with their own warnings) and keep going. Direct `template()`
            # calls still raise — an explicit registration deserves the error.
            Typelizer.logger.warn("#{e.message} — skipping #{path}")
          end
        end
      end

      def template_for(absolute_path, views_root: default_views_root)
        registry[absolute_path] ||
          shadowing_registration(absolute_path, views_root) ||
          auto_register_partial(absolute_path, views_root)
      end

      def registry
        @registry ||= {}
      end

      # relative-path → class, first registration winning the slot: the
      # cross-root shadowing index (Rails view-path semantics — the first
      # root containing a relative path renders it).
      def relative_registry
        @relative_registry ||= {}
      end

      # Every views root seen this cycle, absolute, in registration order.
      # Multi-root apps reference partials across roots like Rails' view-path
      # stack — the resolver falls back to these after the own root misses.
      def views_roots
        @views_roots ||= []
      end

      # One full re-discovery from a clean slate at the start of each
      # generation cycle, so template adds/edits/renames/deletes are picked up
      # without a restart. No-op without discovery roots: production never
      # discovers, and explicit `discover` registrations are left untouched.
      def refresh!
        return unless enabled?

        roots = Array(Typelizer.configuration.jbuilder_views).map(&:to_s)
        return if roots.empty?

        GenerationLock.synchronize do
          # Checked under the lock so a suppression started by another
          # caller is never raced past.
          return if refresh_suppressed?

          reset!
          roots.each { |root| discover(root) }
        end
      end

      # One discovery refresh shared by a whole multi-writer pass: `refresh!`
      # once up front, then suppress the per-writer refresh for the block so
      # `Generator#call` does a single reset!+glob+reparse. Depth-counted
      # (not a boolean) so a nested `refresh_once` can't clear an outer
      # pass's suppression mid-flight; race-free because the reentrant
      # GenerationLock is held throughout.
      def refresh_once
        GenerationLock.synchronize do
          refresh!
          @refresh_depth = refresh_depth + 1
          begin
            yield
          ensure
            @refresh_depth -= 1
          end
        end
      end

      # Clears only per-discovery state: the path→class registry, the
      # `Templates::` constants, the jbuilder `base_classes` entries, and the
      # Walker's parse cache. Cross-cycle state — config, walker activation,
      # adapter registries — survives.
      def reset!
        registry.clear
        relative_registry.clear
        views_roots.clear
        prefix = "#{Templates.name}::"
        Typelizer.base_classes.delete_if { |name| name.start_with?(prefix) }
        Templates.constants.each { |c| Templates.send(:remove_const, c) }
        # Guarded so `reset!` never forces prism activation for users who
        # never parsed a template in this process.
        SerializerPlugins::Jbuilder::Walker.reset_cache! if SerializerPlugins::Jbuilder.walker_activated?
      end

      # A `reject_class` predicate that excludes serializers matching the
      # patterns while keeping every jbuilder template — for a staged migration
      # off another serializer library without `index.ts` collisions.
      #
      #   config.reject_class = Typelizer::Jbuilder.exclude(/Resource\z/)
      def exclude(*patterns)
        prefix = "#{Templates.name}::"
        ->(serializer:) {
          name = serializer.name.to_s
          next false if name.start_with?(prefix)
          patterns.any? { |p| p.is_a?(Regexp) ? name.match?(p) : name.include?(p) }
        }
      end

      private

      # `views_root` must already be absolute (both call sites normalize at
      # entry). Order-preserving dedup: first registration wins the slot.
      def track_views_root(views_root)
        views_roots << views_root unless views_roots.include?(views_root)
      end

      def refresh_depth
        @refresh_depth ||= 0
      end

      def refresh_suppressed?
        refresh_depth > 0
      end

      # The path relative to its views root, or nil when outside it.
      def relative_key(full_path, views_root)
        prefix = "#{views_root}/"
        full_path.delete_prefix(prefix) if full_path.start_with?(prefix)
      end

      # A template that exists on disk in THIS root but is shadowed by an
      # earlier root resolves to the winner's class — Rails renders the
      # winner, so types must reference it too.
      def shadowing_registration(absolute_path, views_root)
        rel = relative_key(absolute_path, File.expand_path(views_root.to_s))
        rel && relative_registry[rel]
      end

      # Removes a superseded registration's constant and generation entry
      # (the path key in `registry` has already been overwritten).
      def remove_registration(klass)
        Typelizer.base_classes.delete(klass.name)
        const_name = klass.name.split("::").last.to_sym
        if Templates.const_defined?(const_name, false) && Templates.const_get(const_name, false).equal?(klass)
          Templates.send(:remove_const, const_name)
        end
      end

      def check_name_collision!(type_name, full_path)
        return unless Templates.const_defined?(type_name, false)

        existing = Templates.const_get(type_name, false)
        existing_path = existing.respond_to?(:_template_path) ? existing._template_path : nil
        return if existing_path.nil? || existing_path == full_path

        raise NameCollision, "Typelizer::Jbuilder: type name #{type_name.inspect} is declared by " \
          "both #{existing_path} and #{full_path} — rename one of them with `typelize_as`"
      end

      def auto_register_partial(absolute_path, views_root)
        return nil unless File.exist?(absolute_path) && File.basename(absolute_path).start_with?("_")

        metadata = SerializerPlugins::Jbuilder.activate_walker!.metadata_for(absolute_path)
        template(absolute_path, views_root: views_root, model: metadata[:model], as: metadata[:type_name])
      end

      def ensure_class(type_name)
        return Templates.const_get(type_name, false) if Templates.const_defined?(type_name, false)

        klass = Class.new
        Templates.const_set(type_name, klass)
        klass.include(DSL)
        klass
      end

      # Generated names are both Ruby constants (under `Templates::`) and TS
      # identifiers. Path-derived names are sanitized to this shape; explicit
      # `typelize_as` names must already conform (never silently rewritten).
      VALID_TYPE_NAME = /\A[A-Z][A-Za-z0-9_]*\z/

      def validate_type_name!(type_name, full_path)
        return type_name if type_name.match?(VALID_TYPE_NAME)

        raise Typelizer::Error, "Typelizer::Jbuilder: #{full_path}: #{type_name.inspect} is not a " \
          "valid type name (must match #{VALID_TYPE_NAME.inspect}) — " \
          "use `typelize_as \"PascalCaseName\"` to set a valid one"
      end

      # Rails convention: a `_foo.json.jbuilder` partial inside `foos/`
      # represents `Foo`, so we drop the redundant directory; other layouts
      # keep the full path to avoid collisions. Each segment is sanitized to
      # constant-safe form (`v2.1` → `V21`, digit-leading `2fa` → `N2fa`); if
      # that still can't produce a valid name, we raise with a `typelize_as` hint.
      def derive_type_name(full_path, views_root)
        rel = full_path.sub(%r{\A#{Regexp.escape(views_root)}/?}, "")
          .sub(/\.json\.jbuilder\z/, "")
          .sub(/\.jbuilder\z/, "")
        parts = rel.split("/")
        parts = collapse_partial_parent(parts)
        name = parts.map { |part| sanitize_segment(part.delete_prefix("_")) }.join
        # `_show.json.jbuilder` beside `show.json.jbuilder` (a common Rails
        # pair) derives the SAME name; the partial takes a "Partial" suffix
        # so the pair coexists — `typelize_as` overrides as usual. Pairs the
        # collapse rule already disambiguates (`posts/_post` → `Post` beside
        # `posts/post` → `PostsPost`) keep their names.
        name += "Partial" if partial_sibling_collision?(full_path, views_root, name)
        validate_type_name!(name, full_path)
      end

      def partial_sibling_collision?(full_path, views_root, name)
        basename = File.basename(full_path)
        return false unless basename.start_with?("_")

        sibling = File.join(File.dirname(full_path), basename.delete_prefix("_"))
        return false unless File.exist?(sibling)

        # The sibling is not a partial, so this cannot recurse.
        derive_type_name(sibling, views_root) == name
      rescue Typelizer::Error
        false
      end

      def sanitize_segment(segment)
        cleaned = segment.gsub(/[^A-Za-z0-9_]/, "").camelize
        cleaned.match?(/\A\d/) ? "N#{cleaned}" : cleaned
      end

      def collapse_partial_parent(parts)
        return parts unless parts.size >= 2 && parts.last.start_with?("_")

        basename = parts.last.delete_prefix("_")
        parent_singular = parts[-2].singularize
        return parts unless basename == parent_singular || basename.start_with?("#{parent_singular}_")

        parts[0..-3] + [parts.last]
      end

      def default_views_root
        if defined?(::Rails) && ::Rails.respond_to?(:root)
          ::Rails.root.join("app", "views").to_s
        else
          File.expand_path("app/views")
        end
      end
    end
  end
end
