# frozen_string_literal: true

require "set"

module Typelizer
  class RouteGenerator
    FORMAT_SUFFIX = /\(\.:format\)$/

    def self.call(**args)
      new.call(**args)
    end

    def call(force: false, skip_check: false)
      return [] if !skip_check && !(Typelizer.enabled? && config.enabled)

      routes = collect_routes
      return [] if routes.empty?

      RouteWriter.new(config).call(routes, force: force)
    end

    private

    def config
      Typelizer.configuration.routes
    end

    def collect_routes
      return [] unless defined?(Rails) && Rails.application

      # Rails 8+ lazily loads routes
      if Rails.application.respond_to?(:reload_routes_unless_loaded)
        Rails.application.reload_routes_unless_loaded
      end

      named_paths = build_named_paths(Rails.application.routes.named_routes)

      routes = Rails.application.routes.routes.flat_map do |route|
        app = route.app.app
        if app.is_a?(Class) && app < Rails::Engine
          collect_engine_routes(route, app) || []
        else
          build_route_info(route, named_paths)
        end
      end.compact

      # Skip PUT where PATCH exists for the same route (Rails adds both for `resources`)
      patch_keys = routes.select { |r| r[:verb] == "patch" }
        .map { |r| [r[:controller], r[:action], r[:path]] }.to_set
      routes.reject! { |r| r[:verb] == "put" && patch_keys.include?([r[:controller], r[:action], r[:path]]) }

      if config.include
        patterns = Array(config.include)
        routes = routes.select { |r| patterns.any? { |p| match_route?(r, p) } }
      end
      if config.exclude
        patterns = Array(config.exclude)
        routes = routes.reject { |r| patterns.any? { |p| match_route?(r, p) } }
      end

      routes
    end

    def match_route?(route_info, pattern)
      if pattern.respond_to?(:call)
        pattern.call(route_info)
      else
        route_info[:path].match?(pattern)
      end
    end

    def build_named_paths(named_routes, path_prefix: "")
      named_routes.each_with_object(Set.new) do |(_name, route), paths|
        controller = route.requirements[:controller]
        action = route.requirements[:action]
        next unless controller && action

        paths << [controller, path_prefix + strip_format(route.path.spec.to_s)]
      end
    end

    def strip_format(path)
      path.sub(FORMAT_SUFFIX, "")
    end

    def build_route_info(route, named_paths)
      controller = route.requirements[:controller]
      action = route.requirements[:action]

      path = strip_format(route.path.spec.to_s)

      if controller.present? && action.present?
        # Match by [controller, path] so unnamed aliases at distinct paths (e.g. ActiveStorage representations) don't inherit a sibling's name
        name = route.name || (action if named_paths.include?([controller, path]))
      elsif route.name.present?
        name = route.name.to_s
        controller = "_routes"
        action = name
      end

      return unless name

      verb = extract_verb(route)
      return unless verb

      required_parts = route.required_parts.map(&:to_s)
      optional_parts = (route.path.optional_names || []).map(&:to_s) - ["format"]

      {
        name: name,
        named: !!route.name,
        controller: controller,
        action: action,
        verb: verb,
        path: path,
        required_parts: required_parts,
        optional_parts: optional_parts
      }
    end

    def collect_engine_routes(mount_route, engine)
      mount_prefix = mount_route.path.spec.to_s
      engine_name = mount_route.name
      return unless engine_name

      named_paths = build_named_paths(engine.routes.named_routes, path_prefix: mount_prefix)

      engine.routes.routes.filter_map do |engine_route|
        info = build_route_info(engine_route, named_paths)
        next unless info
        info[:path] = mount_prefix + info[:path]
        info
      end
    end

    def extract_verb(route)
      verb = route.verb
      return nil if verb.blank?

      verb.split("|").first&.strip&.downcase
    end
  end
end
