# frozen_string_literal: true

require_relative "base"

module Typelizer
  module SerializerPlugins
    # Boot-safe entry point for the jbuilder template plugin: emits Property
    # objects by walking a template's Prism AST. Part of the eager require
    # chain, so it must load without the prism/jbuilder gems — all `Prism::*`
    # code lives in `jbuilder/walker.rb`, loaded lazily via `.activate_walker!`
    # at discovery/generation time, never at boot or render.
    class Jbuilder < Base
      PRISM_REQUIREMENT = ">= 1.0"

      class << self
        # Activates prism and loads the Walker (memoized). The post-require
        # `Prism::VERSION` assertion is the real guard, not the `gem`
        # constraint: on Ruby 3.3+ another tool may have pre-activated an old
        # bundled prism (0.19), making the constraint a no-op.
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

      # `typelize:` props arrive `user_asserted` from the walker, so
      # `Interface#infer_types` already skips model inference per-property — no
      # class-level registry needed.
      def properties
        walker.properties
      end

      def root_is_array
        walker.root_is_array
      end

      # Element type of a root `json.array! @xs, partial: "xs/x"`: the partial's
      # Interface (imported by name, `type X = Array<Element>;`), "unknown" when
      # unresolvable/empty (`Array<unknown>`), or nil for block-form root arrays
      # (which inline their element shape into `...Data`).
      def root_array_element
        walker.root_array_element
      end

      # Post-inference hook (`Interface#properties`): the walker's nil/"unknown"
      # emissions can still be rescued by model inference, so only a property
      # whose FINAL type is unknown warns, at the line the walker recorded.
      def after_type_inference(props)
        props.each { |prop| warn_unknown_property(prop) }
      end

      private

      def warn_unknown_property(prop)
        unless final_unknown?(prop)
          # Recurse into inline shapes (own type + intersection members).
          # Checked after the cheap unknown test so typed leaves allocate
          # nothing; an unknown-typed prop never carries Shape members.
          prop.type.properties.each { |sub| warn_unknown_property(sub) } if prop.type.is_a?(Shape)
          prop.additional_types&.each do |member|
            member.properties.each { |sub| warn_unknown_property(sub) } if member.is_a?(Shape)
          end
          return
        end

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

      # Rails partial-lookup semantics: a bare name resolves against the
      # template's own directory first, a prefixed name against the views root.
      # After the own root misses, sibling roots are tried in registration
      # order (multi-root apps). Each candidate carries its owning root, so a
      # cross-root partial registers under ITS root.
      def resolve_partial_to_class(partial_path)
        partial_candidate_paths(partial_path).each do |path, root|
          klass = Typelizer::Jbuilder.template_for(path, views_root: root)
          return klass if klass
        end
        nil
      end

      # Ordered [absolute candidate path, owning views root] pairs. Bare names
      # are projected onto sibling roots at the template's directory relative to
      # its own root (like Rails resolving a bare `render "x"` in every view path).
      def partial_candidate_paths(partial_path)
        basename = "_#{File.basename(partial_path)}.json.jbuilder"
        own_root = File.expand_path(views_root)
        candidates = []

        if partial_path.include?("/")
          dir = File.dirname(partial_path)
          ([own_root] + sibling_roots(own_root)).each do |root|
            candidates << [File.expand_path(File.join(root, dir, basename)), root]
          end
        else
          template_dir = File.dirname(File.expand_path(template_path))
          candidates << [File.expand_path(File.join(template_dir, basename)), own_root]
          candidates << [File.expand_path(File.join(own_root, basename)), own_root]
          if (rel_dir = template_dir_below(own_root, template_dir))
            sibling_roots(own_root).each do |root|
              candidates << [File.expand_path(File.join(root, rel_dir, basename)), root]
            end
          end
        end

        candidates.uniq
      end

      # Other registered discovery roots, own root excluded, registration
      # order preserved. Empty for single-root apps — fallback resolution
      # then changes nothing.
      def sibling_roots(own_root)
        Typelizer::Jbuilder.views_roots - [own_root]
      end

      # The template's directory relative to its own views root ("posts";
      # "." at the root itself), or nil when the template lives outside the
      # root — bare partial names then can't be projected onto sibling roots.
      def template_dir_below(own_root, template_dir)
        return "." if template_dir == own_root
        return nil unless template_dir.start_with?("#{own_root}/")

        template_dir.delete_prefix("#{own_root}/")
      end
    end
  end
end
