module Typelizer
  class Railtie < Rails::Railtie
    rake_tasks do
      load "tasks/generate.rake"
    end

    initializer "typelizer.configure" do
      Typelizer.configure do |c|
        c.dirs = [
          Rails.root.join("app", "resources"),
          Rails.root.join("app", "serializers")
        ]
      end
    end

    initializer "typelizer.generate" do |app|
      next unless Typelizer.enabled?

      generator = Typelizer::Generator.new

      if Typelizer.listen == true || Gem.loaded_specs["listen"] && Typelizer.listen != false
        require_relative "listen"
        app.config.after_initialize do
          Typelizer::Listen.call do
            Rails.application.reloader.reload!
          end
        end
      end

      app.config.to_prepare do
        generator.call
      end
    end
  end
end
