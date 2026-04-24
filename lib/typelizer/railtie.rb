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
