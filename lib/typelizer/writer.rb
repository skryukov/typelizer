# frozen_string_literal: true

require "fileutils"

module Typelizer
  class Writer
    class WriterError < StandardError; end

    def initialize(config)
      @template_cache = {}
      @config = config
    end

    def call(interfaces, force:)
      cleanup_output_dir if force

      valid_interfaces = interfaces.reject(&:empty?)
      return [] if valid_interfaces.empty?

      written_files = []

      begin
        written_files.concat(valid_interfaces.map { |interface| write_interface(interface) })

        written_files << write_index(valid_interfaces)

        cleanup_stale_files(written_files) unless force

        Typelizer.logger.debug("Generated #{written_files.size} TypeScript files in #{config.output_dir}")

        written_files
      rescue => e
        # if during the file generations an error appears, we remove generated files
        cleanup_partial_writes(written_files)
        raise WriterError, "Failed to write TypeScript files (#{e.class}): #{e.message}"
      end
    end

    private

    attr_reader :config, :template_cache

    def cleanup_stale_files(written_files)
      return unless File.directory?(config.output_dir)

      existing_files = Dir[File.join(config.output_dir, "**/*.ts")]
      stale_files = existing_files - written_files

      File.delete(*stale_files) unless stale_files.empty?
    end

    def write_index(interfaces)
      write_file("index.ts", interfaces.map(&:filename).join) do
        render_template("index.ts.erb", interfaces: interfaces)
      end
    end

    def write_interface(interface)
      write_file("#{interface.filename}.ts", interface.fingerprint) do
        # Use select_interface template for SelectInterface instances
        template = interface.is_a?(SelectInterface) ? "select_interface.ts.erb" : "interface.ts.erb"
        render_template(template, interface: interface)
      end
    end

    def write_file(filename, fingerprint)
      output_file = File.join(config.output_dir, filename)
      existing_content = File.exist?(output_file) ? File.read(output_file) : nil
      digest = render_template("fingerprint.ts.erb", fingerprint: fingerprint)

      return output_file if existing_content&.start_with?(digest)

      content = yield

      FileUtils.mkdir_p(File.dirname(output_file))

      File.write(output_file, digest + content)
      output_file
    end

    def render_template(template, **context)
      template_cache[template] ||= Renderer.new(template)
      template_cache[template].call(**context)
    end

    def cleanup_output_dir
      FileUtils.rm_rf(config.output_dir)
    end

    def cleanup_partial_writes(partial_files)
      File.delete(*partial_files) unless partial_files.empty?
    end
  end
end
