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
        return if Typelizer.listen == false
        return unless Typelizer.listen || Gem.loaded_specs["listen"]

        @block = block
        @generator = Typelizer::Generator.new

        gem "listen"
        require "listen"

        self.started = true

        watched_dirs = Typelizer.dirs.filter(&:exist?).map { |path| File.expand_path(path) }

        relative_paths = watched_dirs.map { |path| relative_path(path) }
        debug("Watching #{relative_paths.inspect}")

        listener(watched_dirs.map(&:to_s), options).start
        @generator.call if run_on_start

        if Typelizer.configuration.routes.enabled
          RouteGenerator.call if run_on_start
          start_route_listener(options)
        end

        start_jbuilder_listener(options) if Typelizer::Jbuilder.enabled?
      end

      private

      def relative_path(path)
        @root_path ||= defined?(Rails) ? Rails.root : Pathname.pwd
        Pathname.new(path).relative_path_from(@root_path).to_s
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

      def start_route_listener(options)
        config_dir = @root_path.join("config")
        return unless config_dir.exist?

        debug("Watching #{relative_path(config_dir)} for route changes")

        ::Listen.to(config_dir.to_s, only: /routes/, **options) do |changed, added, removed|
          debug("Routes changed: #{(changed + added + removed).map { |f| relative_path(f) }.inspect}")
          RouteGenerator.call
        end.start
      end

      # Second listener for jbuilder templates (mirrors `start_route_listener`).
      # The configured `jbuilder_views` roots get their own watcher rather
      # than joining `Typelizer.dirs`, whose `**/*.rb` require semantics
      # don't fit view templates. Triggers the same reload path as the
      # serializer listener; the actual re-discovery happens inside the next
      # generation cycle, behind GenerationLock.
      def start_jbuilder_listener(options)
        dirs = Array(Typelizer.configuration.jbuilder_views)
          .map { |dir| File.expand_path(dir.to_s) }
          .select { |dir| File.directory?(dir) }
        return if dirs.empty?

        debug("Watching #{dirs.map { |dir| relative_path(dir) }.inspect} for jbuilder template changes")

        # Matches the discovery glob (`**/*.json.jbuilder`): other .jbuilder
        # flavors (xml) never produce types, so their edits shouldn't trigger
        # reload cycles.
        ::Listen.to(*dirs, only: /\.json\.jbuilder\z/, **options) do |changed, added, removed|
          debug("Jbuilder templates changed: #{(changed + added + removed).map { |f| relative_path(f) }.inspect}")
          @block.call
        end.start
      end
    end
  end
end
