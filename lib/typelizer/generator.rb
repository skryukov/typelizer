# frozen_string_literal: true

module Typelizer
  class Generator
    def self.call(**args)
      new.call(**args)
    end

    def call(force: false, skip_check: false)
      return [] unless skip_check || Typelizer.enabled?

      # The whole multi-writer pass is one atomic generation cycle: the
      # reentrant GenerationLock keeps a concurrent trigger (middleware,
      # listen, rake) from re-running discovery mid-pass, and jbuilder
      # template re-discovery runs once for the pass instead of once per
      # writer (see Typelizer::Jbuilder.refresh_once).
      GenerationLock.synchronize do
        Typelizer::Jbuilder.refresh_once do
          # Materialize every writer's interfaces up front: the protected-dir
          # union must include per-serializer `output_dir` overrides from ALL
          # writers before the first writer's stale-file cleanup runs.
          writer_batches = Typelizer.configuration.writers.filter_map do |writer_name, writer_config|
            interfaces = Typelizer.interfaces(writer_name: writer_name)
            [writer_config, interfaces] unless interfaces.empty?
          end

          protected_dirs = protected_output_dirs(writer_batches)

          writer_batches.each do |writer_config, interfaces|
            Writer.new(writer_config, protected_output_dirs: protected_dirs).call(interfaces, force: force)
          end
        end
      end
    end

    private

    # Every configured writer's output dir PLUS every per-interface override
    # (`typelizer_config { |c| c.output_dir = ... }` at the serializer level)
    # — handed to each Writer so its cross-writer stale-file protection
    # covers overrides that point into another writer's dir, without reaching
    # back into global configuration (the Generator owns the writer loop).
    def protected_output_dirs(writer_batches)
      writer_dirs = Typelizer.configuration.writers.values.map(&:output_dir)
      interface_dirs = writer_batches.flat_map { |_, interfaces| interfaces.map { |i| i.config.output_dir } }
      (writer_dirs + interface_dirs).uniq
    end
  end
end
