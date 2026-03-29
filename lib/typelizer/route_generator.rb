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

      name_by_action, name_by_path = build_name_lookups(Rails.application.routes.named_routes)

      routes = Rails.application.routes.routes.flat_map do |route|
        app = route.app.app
        if app.is_a?(Class) && app < Rails::Engine
          collect_engine_routes(route, app) || []
        else
          build_route_info(route, name_by_action, name_by_path)
        end
      end.compact

      # Skip PUT where PATCH exists for the same route (Rails adds both for `resources`)
      patch_keys = routes.select { |r| r[:verb] == "patch" }
        .map { |r| [r[:controller], r[:action], r[:path]] }.to_set
      routes.reject! { |r| r[:verb] == "put" && patch_keys.include?([r[:controller], r[:action], r[:path]]) }

      if config.include
        patterns = Array(config.include)
        routes = routes.select { |r| patterns.any? { |p| r[:path].match?(p) } }
      end
      if config.exclude
        patterns = Array(config.exclude)
        routes = routes.reject { |r| patterns.any? { |p| r[:path].match?(p) } }
      end

      routes
    end

    def build_name_lookups(named_routes, path_prefix: "", name_prefix: "")
      name_by_action = {}
      name_by_path = {}

      named_routes.each do |name, route|
        controller = route.requirements[:controller]
        action = route.requirements[:action]
        next unless controller && action

        path = path_prefix + strip_format(route.path.spec.to_s)
        prefixed_name = "#{name_prefix}#{name}"
        name_by_action[[controller, action]] = prefixed_name
        name_by_path[[controller, path]] = prefixed_name
      end

      [name_by_action, name_by_path]
    end

    def strip_format(path)
      path.sub(FORMAT_SUFFIX, "")
    end

    def build_route_info(route, name_by_action, name_by_path)
      controller = route.requirements[:controller]
      action = route.requirements[:action]

      path = strip_format(route.path.spec.to_s)

      if controller.present? && action.present?
        has_own_name = !!route.name
        name = route.name || name_by_action[[controller, action]]
        name ||= name_by_path[[controller, path]] ? action : nil
      elsif route.name.present?
        has_own_name = true
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
        named: has_own_name || !!name_by_action[[controller, action]],
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

      name_by_action, name_by_path = build_name_lookups(
        engine.routes.named_routes,
        path_prefix: mount_prefix,
        name_prefix: "#{engine_name}_"
      )

      engine.routes.routes.filter_map do |engine_route|
        info = build_route_info(engine_route, name_by_action, name_by_path)
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
