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

    # Render-safety patches for jbuilder templates, installed whenever the
    # jbuilder gem is present — independently of whether the typelizer
    # jbuilder plugin is enabled (`Typelizer::Jbuilder.enabled?` gates only
    # discovery, template parsing, and prism activation). Templates annotated
    # with `typelize:` / `typelize_as` / `typelize_from` must render cleanly
    # even where Typelizer's discovery config is development-only: a type
    # annotation must never 500 a production render.
    #
    # `TemplateHelpers` makes the top-of-file declarations no-ops at render
    # time; `SetExt` strips inline `typelize:` kwargs before jbuilder's
    # `set!` sees them. The plugin reads both statically via Prism.
    initializer "typelizer.jbuilder_render_safety" do
      ActiveSupport.on_load(:action_view) do
        next unless Gem.loaded_specs["jbuilder"] || defined?(::Jbuilder)

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
