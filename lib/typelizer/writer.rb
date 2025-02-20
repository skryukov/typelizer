# frozen_string_literal: true

require "fileutils"

module Typelizer
  class Writer
    def initialize
      @template_cache = {}
      @config = Config
    end

    attr_reader :config, :template_cache

    def call(interfaces, force:)
      cleanup_output_dir if force

      written_files = interfaces.map { |interface| write_interface(interface) }
      written_files << write_index(interfaces)

      existing_files = Dir[File.join(config.output_dir, "**/*.ts")]
      files_to_delete = existing_files - written_files

      File.delete(*files_to_delete) unless files_to_delete.empty?
    end

    private

    def write_index(interfaces)
      write_file("index.ts", interfaces.map(&:filename).join) do
        render_template("index.ts.erb", interfaces: interfaces)
      end
    end

    def write_interface(interface)
      write_file("#{interface.filename}.ts", interface.fingerprint) do
        render_template("interface.ts.erb", interface: interface)
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
  end
end
