# frozen_string_literal: true

require_relative "base"

module Typelizer
  module SerializerPlugins
    # Boot-safe entry point for the jbuilder template plugin: emits Property
    # objects by walking a template's Prism AST.
    #
    # This file is part of Typelizer's eager require chain, so it must stay
    # loadable without the `prism` (or `jbuilder`) gem installed. Everything
    # that references `Prism::*` lives in `jbuilder/walker.rb`, which is
    # loaded lazily through `.activate_walker!` the first time a template is
    # parsed — discovery/generation time, never boot or render time.
    class Jbuilder < Base
      PRISM_REQUIREMENT = ">= 1.0"

      class << self
        # Activates the prism gem and loads the Walker, memoizing after the
        # first successful activation. Returns the Walker class.
        #
        # The post-require `Prism::VERSION` assertion is the authoritative
        # guard, not the `gem` constraint: on Ruby 3.3+ prism ships as a
        # bundled gem, so another tool in the process may have pre-activated
        # an old prism (0.19), turning the version constraint into a no-op.
        def activate_walker!
          return Walker if @walker_activated

          begin
            gem "prism", PRISM_REQUIREMENT
            require "prism"
          rescue ::LoadError # includes Gem::LoadError from the `gem` constraint
            prism_activation_error!
          end

          prism_activation_error! unless Gem::Version.new(Prism::VERSION) >= Gem::Version.new("1.0")

          require_relative "jbuilder/walker"
          @walker_activated = true
          Walker
        end

        def walker_activated?
          defined?(@walker_activated) ? !!@walker_activated : false
        end

        private

        def prism_activation_error!
          details =
            if defined?(Prism) && defined?(Prism::VERSION)
              "prism #{Prism::VERSION} is active; the Jbuilder plugin needs >= 1.0"
            else
              "prism could not be loaded"
            end

          raise Typelizer::Error,
            "Typelizer's Jbuilder plugin requires prism >= 1.0 to parse templates — " \
            "add prism (>= 1.0) to your Gemfile (#{details})"
        end
      end

      # `typelize:` kwargs arrive as `user_asserted` properties straight from
      # the walker — `Interface#infer_types` skips AR model inference for
      # them per property (scoped to their nesting level), so no class-level
      # registry mutation is needed here.
      def properties
        walker.properties
      end

      def root_is_array
        walker.root_is_array
      end

      # Post-inference hook called by `Interface#properties` once final types
      # are known. The walker's nil/"unknown" emissions can still be rescued
      # by model inference (a bound AR column overwrites the walker's guess —
      # see `Interface#infer_types`), so the walker itself cannot honestly
      # warn; only a property whose FINAL type is still unknown earns the
      # development warning, with the file:line the walker recorded.
      def after_type_inference(props)
        props.each { |prop| warn_unknown_property(prop) }
      end

      private

      def warn_unknown_property(prop)
        # Recurse into inline shapes first (own type and trailing
        # intersection members) — nested props record their own lines.
        ([prop.type] + Array(prop.additional_types)).grep(Shape).each do |shape|
          shape.properties.each { |sub| warn_unknown_property(sub) }
        end

        return unless final_unknown?(prop)

        # No recorded line means the property didn't originate from this
        # template's walk (e.g. merged in from a top-level `json.partial!` —
        # the partial's own interface warns with the partial's path:line).
        line = walker.unknown_candidates[prop.name.to_s]
        return unless line

        key = [template_path, prop.name.to_s, line]
        warned = walker.class.warned_unknowns
        return if warned.include?(key)

        warned << key
        Typelizer.logger.warn(
          "Typelizer::Jbuilder: #{template_path}:#{line}: could not infer a type for `#{prop.name}` — " \
          "emitted `unknown`; pin it with `typelize:` (e.g. `json.#{prop.name} ..., typelize: \"string\"`)"
        )
      end

      def final_unknown?(prop)
        return false if prop.user_asserted || prop.enum

        walker.class.unknown_type?(prop.type)
      end

      def walker
        @walker ||= self.class.activate_walker!.new(
          path: template_path,
          partial_resolver: method(:resolve_partial_to_class),
          context: context,
          column_inference: column_inference_available?
        )
      end

      def template_path
        serializer._template_path
      end

      def views_root
        serializer._views_root ||
          config.plugin_configs.dig(:jbuilder, :views_root) ||
          "app/views"
      end

      # Column inference only produces types when the bound model is an AR
      # class; for PORO `typelize_from` targets (or no model at all) the
      # walker falls back to name hints instead of emitting all-`unknown`.
      def column_inference_available?
        model = serializer.respond_to?(:_typelizer_model_name) ? serializer._typelizer_model_name : nil
        !!(model.is_a?(Class) && defined?(::ActiveRecord::Base) && model < ::ActiveRecord::Base)
      end

      # Rails partial-lookup semantics: a bare name (`json.partial! "post"`)
      # resolves against the current template's directory first; a prefixed
      # name (`"posts/post"`) resolves against the views root.
      def resolve_partial_to_class(partial_path)
        partial_candidate_paths(partial_path).each do |path|
          klass = Typelizer::Jbuilder.template_for(path, views_root: views_root)
          return klass if klass
        end
        nil
      end

      def partial_candidate_paths(partial_path)
        basename = "_#{File.basename(partial_path)}.json.jbuilder"
        candidates = []
        unless partial_path.include?("/")
          candidates << File.expand_path(File.join(File.dirname(template_path), basename))
        end
        candidates << File.expand_path(File.join(views_root, File.dirname(partial_path), basename))
        candidates.uniq
      end
    end
  end
end
