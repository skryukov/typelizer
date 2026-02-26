# frozen_string_literal: true

module Typelizer
  RouteConfig = Struct.new(
    :enabled,
    :output_dir,
    :include,
    :exclude,
    :camel_case,
    :format,
    keyword_init: true
  )

  class RouteConfig
    def self.defaults
      {
        enabled: false,
        output_dir: nil,
        include: nil,
        exclude: nil,
        camel_case: true,
        format: :ts
      }
    end

    def ts?
      format != :js
    end

    def js?
      format == :js
    end

    def file_ext
      js? ? "js" : "ts"
    end

    def self.build(**overrides)
      new(**defaults.merge(overrides))
    end

    def output_dir
      self[:output_dir] || begin
        root_path = defined?(Rails) ? Rails.root : Pathname.pwd
        js_root = defined?(ViteRuby) ? ViteRuby.config.source_code_dir : "app/javascript"
        root_path.join(js_root, "routes")
      end
    end
  end
end
