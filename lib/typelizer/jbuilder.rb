# frozen_string_literal: true

require_relative "error"

module Typelizer
  module Jbuilder
    # Two templates claiming the same type name (via `typelize_as` or
    # path-derived naming). Raised from `discover`/`template`, which only run
    # inside a generation cycle — never at boot — so a collision is a
    # generation-time error, not a production boot crash.
    class NameCollision < Error; end

    module Templates; end

    # Runtime no-op helpers so jbuilder templates can declare
    # `typelize_as "Foo"` / `typelize_from User` at the top of the file.
    # The plugin reads these calls statically via Prism; at render time they
    # don't need to do anything. Auto-included into ActionView::Base via the
    # railtie; can be included manually for non-Rails setups.
    module TemplateHelpers
      def typelize_as(_name)
      end

      def typelize_from(_model)
      end
    end

    # Inline `json.foo value, typelize: "string"` annotations are read by the
    # AST walker for type generation, but at render time they're junk to
    # jbuilder — its `set!` doesn't declare `**kwargs`, so Ruby 3 packs them as
    # a positional Hash and `_extract_method_values` raises
    # `{typelize: "..."} is not a symbol nor a string`.
    #
    # This module strips the typelizer-reserved kwargs before forwarding to
    # upstream `set!`. Prepended onto `JbuilderTemplate` via the railtie
    # whenever the jbuilder gem is present — independently of whether the
    # typelizer jbuilder plugin is enabled — so annotated templates never
    # crash a render in environments where Typelizer is dev-only.
    #
    # Each gem strips its own render-inert vocabulary unconditionally
    # (`typelize:`), but the foreign `inertia:` kwarg is render-ACTIVE and
    # owned by jbuilder-inertia: it is stripped only when that gem's patch is
    # absent from the template class's ancestry (otherwise the directive must
    # pass through untouched, regardless of which gem's patch is outermost).
    #
    # The `method_missing` override is required to defeat jbuilder's
    # `alias_method :method_missing, :set!` quirk (the alias captures the
    # original `set!` body, bypassing any prepended `set!`).
    module SetExt
      RESERVED_KWARGS = %i[typelize].freeze

      # Render-ACTIVE kwargs owned by other gems' prepended template patches,
      # mapped to their owner: the patch constant is matched by NAME so
      # typelizer never has to load (or even know about) those gems. A
      # foreign kwarg is stripped only when its owner patch is absent from
      # the template class's ancestry.
      FOREIGN_KWARGS = {
        inertia: {owner: "JbuilderInertia::JbuilderExt", gem: "jbuilder-inertia"}.freeze
      }.freeze

      class << self
        # Lazy (at strip time, never at patch-install time — `on_load`
        # ordering between the gems follows require order that neither
        # controls) and one-way memoized per owner: once the patch is seen
        # the answer is permanent (a prepended module can never be removed),
        # but while absent we re-check on every strip so a late prepend is
        # picked up by the very next render. The constant-presence check
        # short-circuits the common negative (owner gem not loaded at all)
        # without scanning ancestors.
        #
        # `Jbuilder < BasicObject`, so `template.class` would dispatch into
        # `set!` and emit a "class" key — bind `Object#class` explicitly.
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

      def set!(name, *args, **kwargs, &block)
        # Hot path: a bare `json.foo value` carries no kwargs at all — skip
        # straight to upstream `set!` (this runs once per json.* call).
        return super(name, *args, &block) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)

        # When kwargs is empty, omit them entirely so we don't accidentally
        # forward an empty Hash as a positional arg to upstream `set!` (which
        # has no `**kwargs` in jbuilder's signature — a positional Hash there
        # would be treated as a value). When kwargs is non-empty, splat with
        # `**` so the next prepend in the chain (e.g. jbuilder-inertia's
        # extension) receives them as actual kwargs.
        if kwargs.empty?
          super(name, *args, &block)
        else
          super
        end
      end

      # The non-`set!` emitters need the same protection: jbuilder's
      # signatures (`extract!(object, *attributes)`,
      # `array!(collection = [], *attrs)`, `call(object, *attributes)`)
      # declare no `**kwargs`, so a `typelize:` annotation would pack into
      # the positional attribute list and crash the render. Same
      # top-of-method rule as `set!`; when stripping empties the kwargs they
      # are omitted entirely so no spurious positional Hash reaches upstream.
      # (The walker intentionally ignores `typelize:` here — it has no
      # per-field meaning on multi-attribute emitters.)
      def extract!(object, *attributes, **kwargs)
        return super(object, *attributes) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)

        if kwargs.empty?
          super(object, *attributes)
        else
          super
        end
      end

      def array!(*args, **kwargs, &block)
        return super(*args, &block) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)

        if kwargs.empty?
          super(*args, &block)
        else
          super
        end
      end

      def call(object, *attributes, **kwargs, &block)
        return super(object, *attributes, &block) if kwargs.empty?

        _typelizer_strip_kwargs!(kwargs)

        if kwargs.empty?
          super(object, *attributes, &block)
        else
          super
        end
      end

      private

      # Stripping happens before any other logic (structural R7 rule):
      # foreign-inert kwargs must be gone before any intercept or early
      # return so behavior is identical under either gem's prepend order.
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
      # Whether the jbuilder plugin is enabled for automatic work (template
      # discovery, parsing, prism activation). Auto-detected from discovery
      # config being present (`config.jbuilder_views = [...]`), with
      # `config.jbuilder_enabled = true/false` as an explicit override.
      #
      # This gates ONLY discovery-side behavior. The render-safety patches
      # (`SetExt`, `TemplateHelpers`) install whenever jbuilder is present,
      # regardless of this predicate — see the railtie.
      def enabled?
        override = Typelizer.configuration.jbuilder_enabled
        return override unless override.nil?

        Array(Typelizer.configuration.jbuilder_views).any?
      end

      def template(path, views_root: default_views_root, model: nil, as: nil)
        # Normalize once at entry (mirrors `discover` and the listener):
        # a relative or Pathname root would otherwise double-prefix glob
        # results on re-expansion and crash the type-name derivation.
        views_root = File.expand_path(views_root.to_s)
        track_views_root(views_root)
        full_path = File.expand_path(path, views_root)
        type_name = as ? validate_type_name!(as.to_s, full_path) : derive_type_name(full_path, views_root)
        check_name_collision!(type_name, full_path)

        klass = ensure_class(type_name)
        klass.define_singleton_method(:_template_path) { full_path }
        klass.define_singleton_method(:_views_root) { views_root }
        # Routes column/enum/comment inference through the model-plugin
        # pipeline. The model is stored by NAME and constantized lazily at
        # each generation, so a Zeitwerk reload between cycles always
        # resolves the freshly loaded class (a captured class object would
        # go stale and keep answering with pre-reload columns).
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
        klass
      end

      # Templates own their own type-name and model bindings via top-of-file
      # DSL calls: `typelize_as "Foo"`, `typelize_from User`. `discover`
      # consults the Walker's cached parse so the bindings are fixed at
      # registration time and the same parse is reused later for the
      # property walk.
      def discover(views_root = default_views_root, model_resolver: nil)
        # Same entry normalization as `template`: accept relative paths and
        # Pathnames without double-prefixing the glob results downstream.
        # The root is tracked even when it currently holds no templates, so
        # a partial added there mid-cycle is still reachable via fallback
        # resolution.
        views_root = File.expand_path(views_root.to_s)
        track_views_root(views_root)
        walker = SerializerPlugins::Jbuilder.activate_walker!
        # Sorted for deterministic registration order — stable `index.ts`
        # output and stable collision error messages across filesystems.
        Dir.glob(File.join(views_root, "**/*.json.jbuilder")).sort.each do |path|
          metadata = walker.metadata_for(path)
          model = metadata[:model] || model_resolver&.call(path)
          template(path, views_root: views_root, model: model, as: metadata[:type_name])
        end
      end

      def template_for(absolute_path, views_root: default_views_root)
        registry[absolute_path] || auto_register_partial(absolute_path, views_root)
      end

      def registry
        @registry ||= {}
      end

      # Every views root seen by `template`/`discover` in the current
      # discovery cycle, absolute, in registration order. Multi-root apps
      # (e.g. a core/enterprise split registered as separate `discover`
      # calls or `jbuilder_views` entries) reference partials across roots
      # exactly like Rails' view-path stack — the partial resolver falls
      # back to these siblings after the template's own root misses.
      def views_roots
        @views_roots ||= []
      end

      # One full re-discovery from a clean slate, run at the start of every
      # generation cycle (`Typelizer.interfaces`) under the shared
      # GenerationLock — template adds/edits/renames/deletes are reflected
      # on the next cycle without a process restart. No-op unless discovery
      # roots are configured: production boots never discover (generation
      # simply doesn't run there unless `rake typelizer:generate` explicitly
      # asks), and explicit `discover` registrations (non-Rails flows
      # without `jbuilder_views`) are left untouched.
      def refresh!
        return if @refresh_suppressed
        return unless enabled?

        roots = Array(Typelizer.configuration.jbuilder_views).map(&:to_s)
        return if roots.empty?

        GenerationLock.synchronize do
          reset!
          roots.each { |root| discover(root) }
        end
      end

      # One discovery refresh shared by a whole multi-writer generation pass:
      # runs `refresh!` once up front, then suppresses the per-writer
      # `Typelizer.interfaces` refresh for the duration of the block, so
      # `Generator#call` does a single reset!+glob+reparse instead of one per
      # writer. Direct `Typelizer.interfaces` callers (rake openapi, specs)
      # still refresh. The plain module flag is race-free because callers
      # hold the reentrant GenerationLock for the whole block, so no other
      # thread can enter `refresh!` until the flag is cleared.
      def refresh_once
        refresh!
        @refresh_suppressed = true
        yield
      ensure
        @refresh_suppressed = false
      end

      # Clears only per-discovery state: the path→class registry, the
      # generated `Templates::` constants, the jbuilder-registered
      # `Typelizer.base_classes` entries, and the Walker's parse cache.
      # Cross-cycle state — configuration, walker activation, and the
      # extension/resolver registries (U6) — survives: adapter registrations
      # must outlive a single generation cycle.
      def reset!
        registry.clear
        views_roots.clear
        prefix = "#{Templates.name}::"
        Typelizer.base_classes.delete_if { |name| name.start_with?(prefix) }
        Templates.constants.each { |c| Templates.send(:remove_const, c) }
        # Guarded so `reset!` never forces prism activation for users who
        # never parsed a template in this process.
        SerializerPlugins::Jbuilder::Walker.reset_cache! if SerializerPlugins::Jbuilder.walker_activated?
      end

      # Returns a `reject_class` predicate that excludes serializers matching
      # the given name patterns while keeping every jbuilder template. Use
      # during a staged migration from another serializer library to jbuilder
      # to avoid `index.ts` collisions without deleting the legacy Ruby files.
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

      # Generated type names double as Ruby constant names (under
      # `Templates::`) and TypeScript identifiers, so they must match this
      # shape. Path-derived names are sanitized into it (see
      # `sanitize_segment`); explicit `typelize_as` names must already
      # conform — a user-chosen name is never silently rewritten.
      VALID_TYPE_NAME = /\A[A-Z][A-Za-z0-9_]*\z/

      def validate_type_name!(type_name, full_path)
        return type_name if type_name.match?(VALID_TYPE_NAME)

        raise Typelizer::Error, "Typelizer::Jbuilder: #{full_path}: #{type_name.inspect} is not a " \
          "valid type name (must match #{VALID_TYPE_NAME.inspect}) — " \
          "use `typelize_as \"PascalCaseName\"` to set a valid one"
      end

      # Rails convention: a `_foo.json.jbuilder` partial inside `foos/`
      # represents the `Foo` resource, so we drop the redundant directory. Any
      # other layout (e.g. `admin/_user`, `users/_avatar`) keeps the full path
      # to avoid collisions and stay honest about the file's location.
      #
      # Each segment is sanitized deterministically into constant-safe form:
      # characters outside [A-Za-z0-9_] are stripped (`v2.1` → `V21`) and
      # digit-leading segments are prefixed with `N` (`2fa` → `N2fa`). If
      # sanitization still can't produce a valid name, we raise with a
      # `typelize_as` hint instead of letting a bare NameError escape.
      def derive_type_name(full_path, views_root)
        rel = full_path.sub(%r{\A#{Regexp.escape(views_root)}/?}, "")
          .sub(/\.json\.jbuilder\z/, "")
          .sub(/\.jbuilder\z/, "")
        parts = rel.split("/")
        parts = collapse_partial_parent(parts)
        name = parts.map { |part| sanitize_segment(part.delete_prefix("_")) }.join
        validate_type_name!(name, full_path)
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
