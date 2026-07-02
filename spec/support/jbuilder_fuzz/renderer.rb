# frozen_string_literal: true

module JbuilderFuzz
  # Real jbuilder with Typelizer's render-safety patch prepended, exactly as
  # the railtie sets production renders up (SetExt only matters for
  # `typelize:` kwargs, which grammar v1 never emits — prepended anyway so
  # the render side matches a real app's ancestry).
  class RenderBuilder < ::Jbuilder
  end
  RenderBuilder.prepend(Typelizer::Jbuilder::SetExt)

  # Renders a template source string with real jbuilder outside Rails: ivars
  # are bound on a fresh holder object, the source is evaluated with `json`
  # in scope, and the JSON output is parsed back.
  module Renderer
    module_function

    def render(source, ivars)
      holder = Object.new
      ivars.each { |name, value| holder.instance_variable_set("@#{name}", value) }
      holder.define_singleton_method(:__fuzz_run) do |src|
        json = RenderBuilder.new
        eval(src, binding) # standard:disable Security/Eval
        JSON.parse(json.target!)
      end
      holder.__fuzz_run(source)
    end
  end
end
