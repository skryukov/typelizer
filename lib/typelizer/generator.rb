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
          Typelizer.configuration.writers.each do |writer_name, writer_config|
            interfaces = Typelizer.interfaces(writer_name: writer_name)
            next if interfaces.empty?

            Writer.new(writer_config, protected_output_dirs: protected_output_dirs).call(interfaces, force: force)
          end
        end
      end
    end

    private

    # Every configured writer's output dir — handed to each Writer so its
    # cross-writer stale-file protection doesn't reach back into global
    # configuration (the Generator owns the writer loop).
    def protected_output_dirs
      Typelizer.configuration.writers.values.map(&:output_dir)
    end
  end
end
