# frozen_string_literal: true

require "fileutils"

module Typelizer
  class RouteWriter
    def initialize(config)
      @config = config
      @template_cache = {}
    end

    def call(routes, force:)
      FileUtils.rm_rf(config.output_dir) if force

      written_files = []

      controllers = routes.group_by { |r| r[:controller] }
      named = build_named_routes(routes, controllers)

      controllers.each do |controller, controller_routes|
        written_files << write_controller(controller, controller_routes)
      end

      written_files << write_index(controllers, named)

      written_files << write_runtime

      cleanup_stale_files(written_files) unless force

      Typelizer.logger.debug("Generated #{written_files.size} route files in #{config.output_dir}")

      written_files
    end

    private

    attr_reader :config, :template_cache

    def write_controller(controller, routes)
      ctrl_path = controller_filename(controller)
      filename = "#{ctrl_path}.#{config.file_ext}"

      prepared_routes = routes.map do |route|
        key = route_key(route, routes)

        required = route[:required_parts].map { |p| camelize_key(p) }
        optional = route[:optional_parts].map { |p| camelize_key(p) }
        single_required = required.size == 1 && optional.empty?

        route.merge(
          key: key,
          required_params: required,
          optional_params: optional,
          single_required: single_required
        )
      end

      fingerprint = prepared_routes.map { |r| [r[:name], r[:verb], r[:path], r[:key]] }.inspect
      runtime_import = (ctrl_path.count("/") > 0) ? "#{"../" * ctrl_path.count("/")}runtime" : "./runtime"

      write_file(filename, fingerprint) do
        render_template("route_controller.erb", ts: config.ts?, routes: prepared_routes, runtime_import: runtime_import)
      end
    end

    def write_index(controllers, named)
      entries = controllers.map do |controller, _routes|
        {
          namespace: controller_namespace_name(controller),
          file: controller_filename(controller)
        }
      end.sort_by { |e| e[:namespace] }

      fingerprint = [entries, named.map { |n| [n[:export_name], n[:key], n[:controller_file]] }].inspect

      write_file("index.#{config.file_ext}", fingerprint) do
        render_template("route_index.erb", entries: entries, named_routes: named)
      end
    end

    RUNTIME_TEMPLATES = {
      "ts" => File.read(File.join(__dir__, "templates/route_runtime.ts")),
      "js" => File.read(File.join(__dir__, "templates/route_runtime.js"))
    }.freeze

    def write_runtime
      content = RUNTIME_TEMPLATES.fetch(config.file_ext)

      write_file("runtime.#{config.file_ext}", content) do
        content
      end
    end

    def write_file(filename, fingerprint)
      output_file = File.join(config.output_dir, filename)
      digest = render_template("fingerprint.erb", fingerprint: fingerprint)

      existing_header = begin
        File.read(output_file, digest.bytesize)
      rescue
        nil
      end
      return output_file if existing_header == digest

      content = yield

      FileUtils.mkdir_p(File.dirname(output_file))

      File.write(output_file, digest + content)
      output_file
    end

    def cleanup_stale_files(written_files)
      existing_files = Dir[File.join(config.output_dir, "**/*.#{config.file_ext}")]
      stale_files = existing_files - written_files

      File.delete(*stale_files) unless stale_files.empty?
    end

    def render_template(template, **context)
      template_cache[template] ||= Renderer.new(template)
      template_cache[template].call(**context)
    end

    def build_named_routes(routes, controllers)
      controller_namespaces = controllers.keys.map { |c| controller_namespace_name(c) }.to_set

      routes.filter_map do |route|
        next unless route[:named]
        export_name = camelize_key(route[:name])
        next if controller_namespaces.include?(export_name)

        ctrl_routes = controllers[route[:controller]]
        key = route_key(route, ctrl_routes)
        controller_var = "_#{controller_namespace_name(route[:controller])}"

        {
          export_name: export_name,
          key: key,
          controller_file: controller_filename(route[:controller]),
          controller_var: controller_var
        }
      end
    end

    def route_key(route, controller_routes)
      collides = controller_routes.count { |r| r[:action] == route[:action] } > 1
      camelize_key(collides ? route[:name] : route[:action])
    end

    def camelize_key(key)
      config.camel_case ? key.camelize(:lower) : key
    end

    def controller_filename(controller)
      @controller_filenames ||= {}
      @controller_filenames[controller] ||= begin
        parts = controller.split("/")
        parts.map!(&:camelize)
        parts[-1] = "#{parts[-1]}Controller"
        parts.join("/")
      end
    end

    def controller_namespace_name(controller)
      name = controller.tr("/", "_")
      camelize_key(name)
    end
  end
end
