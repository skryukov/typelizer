# frozen_string_literal: true

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
    # The `method_missing` override is required to defeat jbuilder's
    # `alias_method :method_missing, :set!` quirk (the alias captures the
    # original `set!` body, bypassing any prepended `set!`).
    module SetExt
      RESERVED_KWARGS = %i[typelize typelize_from].freeze

      def method_missing(name, *args, **kwargs, &block)
        set!(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        super
      end

      def set!(name, *args, **kwargs, &block)
        RESERVED_KWARGS.each { |k| kwargs.delete(k) }

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
        full_path = File.expand_path(path, views_root)
        type_name = as || derive_type_name(full_path, views_root)
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
          klass.define_singleton_method(:_template_model_name) { model_name }
          klass.define_singleton_method(:_typelizer_model_name) { model_name.safe_constantize }
        elsif model
          # Anonymous class — no name to re-resolve; keep the object.
          klass.define_singleton_method(:_template_model_name) { nil }
          klass.define_singleton_method(:_typelizer_model_name) { model }
        end

        klass.typelizer_config do |c|
          c.serializer_plugin = SerializerPlugins::Jbuilder
          c.serializer_name_mapper = ->(s) { s.name.split("::").last }
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

      # One full re-discovery from a clean slate, run at the start of every
      # generation cycle (`Typelizer.interfaces`) under the shared
      # GenerationLock — template adds/edits/renames/deletes are reflected
      # on the next cycle without a process restart. No-op unless discovery
      # roots are configured: production boots never discover (generation
      # simply doesn't run there unless `rake typelizer:generate` explicitly
      # asks), and explicit `discover` registrations (non-Rails flows
      # without `jbuilder_views`) are left untouched.
      def refresh!
        return unless enabled?

        roots = Array(Typelizer.configuration.jbuilder_views).map(&:to_s)
        return if roots.empty?

        GenerationLock.synchronize do
          reset!
          roots.each { |root| discover(root) }
        end
      end

      # Clears only per-discovery state: the path→class registry, the
      # generated `Templates::` constants, the jbuilder-registered
      # `Typelizer.base_classes` entries, and the Walker's parse cache.
      # Cross-cycle state — configuration, walker activation, and the
      # extension/resolver registries (U6) — survives: adapter registrations
      # must outlive a single generation cycle.
      def reset!
        registry.clear
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

      # Rails convention: a `_foo.json.jbuilder` partial inside `foos/`
      # represents the `Foo` resource, so we drop the redundant directory. Any
      # other layout (e.g. `admin/_user`, `users/_avatar`) keeps the full path
      # to avoid collisions and stay honest about the file's location.
      def derive_type_name(full_path, views_root)
        rel = full_path.sub(%r{\A#{Regexp.escape(views_root)}/?}, "")
          .sub(/\.json\.jbuilder\z/, "")
          .sub(/\.jbuilder\z/, "")
        parts = rel.split("/")
        parts = collapse_partial_parent(parts)
        parts.map { |part| part.delete_prefix("_").camelize }.join
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
