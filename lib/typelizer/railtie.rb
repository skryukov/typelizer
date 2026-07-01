module Typelizer
  class Railtie < Rails::Railtie
    rake_tasks do
      load "tasks/generate.rake"
    end

    initializer "typelizer.configure" do
      Typelizer.configure do |c|
        if c.dirs.empty?
          c.dirs = [
            Rails.root.join("app", "resources"),
            Rails.root.join("app", "serializers")
          ]
        end
      end
    end

    initializer "typelizer.configure_dsl" do
      Typelizer::DSL.disable! unless Typelizer.enabled?
    end

    # Render-safety patches for jbuilder templates, installed whenever jbuilder
    # is present — independent of whether the plugin is enabled (which gates
    # only discovery). A `typelize:`/`typelize_as`/`typelize_from` annotation
    # must never 500 a production render even where discovery is dev-only.
    # `TemplateHelpers` no-ops the declarations; `SetExt` strips the kwargs
    # (see their docs in jbuilder.rb).
    initializer "typelizer.jbuilder_render_safety" do
      ActiveSupport.on_load(:action_view) do
        # Keyed on jbuilder being LOADED, not merely installed: an app with
        # `gem "jbuilder", require: false` that never requires it must not
        # have it force-loaded (and can't render jbuilder templates anyway).
        next unless defined?(::Jbuilder)

        begin
          require "jbuilder/jbuilder_template"
        rescue LoadError
          next
        end

        include Typelizer::Jbuilder::TemplateHelpers
        ::JbuilderTemplate.prepend(Typelizer::Jbuilder::SetExt)
      end
    end

    server do
      next unless Typelizer.enabled?

      require_relative "middleware"
      Rails.application.config.app_middleware.use(Typelizer::Middleware)

      if Typelizer.listen == true || (Gem.loaded_specs["listen"] && Typelizer.listen != false)
        require_relative "listen"
        Typelizer::Listen.call(run_on_start: false) do
          Rails.application.reloader.reload!
        end
      end

      Rails.application.config.to_prepare do
        Typelizer::Middleware.instance&.mark_pending!
      end
    end
  end
end
