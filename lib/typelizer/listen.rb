# frozen_string_literal: true

module Typelizer
  module Listen
    class << self
      attr_accessor :started

      def call(
        run_on_start: true,
        options: {},
        &block
      )
        return if started
        return unless Typelizer.enabled?

        @block = block
        @generator = Typelizer::Generator.new

        gem "listen"
        require "listen"

        self.started = true

        locales_dirs = Typelizer.dirs.filter(&:exist?).map { |path| File.expand_path(path) }

        relative_paths = locales_dirs.map { |path| relative_path(path) }

        debug("Watching #{relative_paths.inspect}")

        listener(locales_dirs.map(&:to_s), options).start
        @generator.call if run_on_start
      end

      def relative_path(path)
        root_path = defined?(Rails) ? Rails.root : Pathname.pwd
        Pathname.new(path).relative_path_from(root_path).to_s
      end

      def debug(message)
        Typelizer.logger.debug(message)
      end

      def listener(paths, options)
        ::Listen.to(*paths, options) do |changed, added, removed|
          changes = compute_changes(paths, changed, added, removed)

          next unless changes.any?

          debug(changes.map { |key, value| "#{key}=#{value.inspect}" }.join(", "))

          @block.call
        end
      end

      def compute_changes(paths, changed, added, removed)
        paths = paths.map { |path| relative_path(path) }

        {
          changed: included_on_watched_paths(paths, changed),
          added: included_on_watched_paths(paths, added),
          removed: included_on_watched_paths(paths, removed)
        }.select { |_k, v| v.any? }
      end

      def included_on_watched_paths(paths, changes)
        changes.map { |change| relative_path(change) }.select do |change|
          paths.any? { |path| change.start_with?(path) }
        end
      end
    end
  end
end
