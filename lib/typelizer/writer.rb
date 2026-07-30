# frozen_string_literal: true

require "fileutils"

require_relative "error"

module Typelizer
  class Writer
    class WriterError < Typelizer::Error; end

    # `protected_output_dirs` is the full set of writer output dirs to shield
    # from this writer's stale-file cleanup (the Generator passes every
    # configured writer's dir). Defaults to reading them from the global
    # configuration so direct `Writer.new(config)` construction keeps the
    # current behavior.
    def initialize(config, protected_output_dirs: nil)
      @template_cache = {}
      @config = config
      @protected_output_dirs = protected_output_dirs
    end

    class << self
      # Per-writer (keyed by output_dir — unique across writers) memo of the
      # last duplicate-export name set we warned about, so the warning fires
      # once per name-set instead of on every generation cycle, and fires
      # again only when the colliding set changes. Class-level because Writer
      # instances are recreated each cycle.
      def warned_duplicate_exports
        @warned_duplicate_exports ||= {}
      end
    end

    def call(interfaces, force:)
      cleanup_output_dir(interfaces) if force

      valid_interfaces = interfaces.reject(&:empty?)
      return [] if valid_interfaces.empty?

      written_files = []

      begin
        written_files.concat(valid_interfaces.map { |interface| write_interface(interface) })

        enums = collect_enums(valid_interfaces)
        written_files << write_enums(enums) if enums.any?

        written_files << write_index(valid_interfaces, enums: enums)

        cleanup_stale_files(written_files, valid_interfaces) unless force

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

    # Stale cleanup never crosses writers: another writer's output_dir may be
    # nested inside this writer's (e.g. a migration-period `types/jbuilder`
    # under the default `types`), and its files must not be collected as
    # stale here — each writer cleans up only its own output.
    def cleanup_stale_files(written_files, interfaces)
      output_dirs = output_dirs_for(interfaces)
      foreign_dirs = foreign_output_dirs(output_dirs)

      existing_files = output_dirs.flat_map { |dir| Dir[File.join(dir, "**/*.ts")] }
      existing_files = existing_files.reject { |file| foreign_dirs.any? { |dir| File.expand_path(file).start_with?(dir) } }
      stale_files = existing_files - written_files

      File.delete(*stale_files) unless stale_files.empty?
    end

    # Output dirs configured for OTHER writers (expanded, with a trailing
    # separator so prefix matching can't cross sibling dirs that merely share
    # a name prefix). A foreign dir that is an ancestor of one of our own
    # dirs is dropped too: files under our own dirs are always ours, and an
    # ancestor prefix would otherwise swallow them.
    def foreign_output_dirs(own_dirs)
      own = own_dirs.map { |dir| File.expand_path(dir.to_s) }
      protected_dirs = @protected_output_dirs || Typelizer.configuration.writers.values.map(&:output_dir)
      protected_dirs
        .map { |dir| File.expand_path(dir.to_s) }
        .uniq
        .reject { |dir| own.include?(dir) || own.any? { |own_dir| own_dir.start_with?(dir + File::SEPARATOR) } }
        .map { |dir| dir + File::SEPARATOR }
    end

    # Two serializers resolving to the same exported type name in one index
    # produce duplicate `export` lines — invalid TS. This is a warning, not
    # an error: during a staged cross-plugin migration (e.g. Alba
    # `PostResource` alongside `posts/_post.json.jbuilder`, both → `Post`)
    # the duplicate sources legitimately coexist in separate writers; the
    # warning fires only when they share ONE index, naming both sources so
    # the writer scoping (`reject_class`) or the name can be fixed.
    def warn_duplicate_exports(interfaces)
      duplicate_groups = interfaces.group_by(&:name).select { |_, group| group.size >= 2 }

      # Dedup across cycles: generation re-runs on every request/file change,
      # and re-warning about the same unchanged duplicate set on each cycle
      # is noise. Re-warn only when the set of colliding names changes. An
      # EMPTY set never touches the memo: two writers sharing an output_dir
      # would otherwise ping-pong (the clean writer clearing the other's
      # marker every cycle). Trade-off: a duplicate that is fixed and later
      # reintroduced identically doesn't re-warn.
      signature = duplicate_groups.keys.sort
      return if signature.empty?

      memo_key = config.output_dir.to_s
      return if self.class.warned_duplicate_exports[memo_key] == signature

      self.class.warned_duplicate_exports[memo_key] = signature

      duplicate_groups.each do |name, group|
        sources = group.map(&:source_description).sort
        Typelizer.logger.warn(
          "Typelizer: duplicate exported type #{name.inspect} in #{File.join(config.output_dir.to_s, "index.ts")} — " \
          "declared by #{sources.join(" and ")}; scope the writers' `reject_class` or rename one " \
            "(`typelize_as` in a jbuilder template, `serializer_name_mapper` for class serializers)"
        )
      end
    end

    def collect_enums(interfaces)
      interfaces
        .flat_map(&:enum_types)
        .uniq(&:enum_type_name)
        .sort_by(&:enum_type_name)
    end

    def write_enums(enums)
      fingerprint = [enums.map(&:fingerprint), config.properties_sort_order, config.prefer_double_quotes, config.enum_runtime].inspect
      write_file("Enums.ts", fingerprint) do
        render_template("enums.ts.erb", enums: enums, sort_order: config.properties_sort_order, prefer_double_quotes: config.prefer_double_quotes, enum_runtime: config.enum_runtime)
      end
    end

    def write_index(interfaces, enums: [])
      warn_duplicate_exports(interfaces)

      fingerprint = [
        enums.map(&:enum_type_name),
        interfaces.map { |i|
          [i.name, i.filename, i.index_path(config.output_dir.to_s), i.trait_interfaces.map(&:name), CONFIGS_AFFECTING_INDEX_OUTPUT.map { |key| i.config.public_send(key) }]
        }
      ].inspect
      write_file("index.ts", fingerprint) do
        render_template("index.ts.erb", interfaces: interfaces, enums: enums, index_dir: config.output_dir.to_s, imports_sort_order: config.imports_sort_order, prefer_double_quotes: config.prefer_double_quotes, enum_runtime: config.enum_runtime)
      end
    end

    def write_interface(interface)
      output_dir = interface.config.output_dir
      write_file("#{interface.filename}.ts", interface.fingerprint, output_dir: output_dir) do
        render_template("interface.ts.erb", interface: interface)
      end
    end

    def write_file(filename, fingerprint, output_dir: config.output_dir)
      output_file = File.join(output_dir, filename)
      existing_content = File.exist?(output_file) ? File.read(output_file) : nil
      digest = render_template("fingerprint.erb", fingerprint: fingerprint)

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

    def cleanup_output_dir(interfaces)
      output_dirs_for(interfaces).each { |dir| FileUtils.rm_rf(dir) }
    end

    def output_dirs_for(interfaces)
      dirs = interfaces.filter_map { |i| i.config.output_dir.to_s unless i.empty? }
      dirs << config.output_dir.to_s
      dirs.uniq
    end

    def cleanup_partial_writes(partial_files)
      File.delete(*partial_files) unless partial_files.empty?
    end
  end
end
