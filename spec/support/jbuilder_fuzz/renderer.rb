# frozen_string_literal: true

module JbuilderFuzz
  # Renders seed templates through the REAL production stack — ActionView
  # compiling .json.jbuilder files into JbuilderTemplate (with Typelizer's
  # SetExt prepended by the railtie) — not a bare ::Jbuilder eval. That is
  # the stack apps actually render with, and it is the only stack where
  # `partial!` / inline-partial / `cache!` forms exist at all. The walker and
  # the renderer read the SAME files under views_root, so what is walked is
  # exactly what renders.
  #
  # Engine notes (see the grammar-v2 dossier work): an anonymous controller's
  # nil controller_path poisons LookupContext prefixes for slash-less partial
  # refs, so we use a bare LookupContext with an explicit prefix instead of
  # controller.renderer. A fresh view class per render (with_empty_template_cache)
  # keeps compiled template methods from leaking across seeds; the grammar
  # gives every seed unique template paths, so resolver-level caching in
  # ActionView::PathRegistry is safe to keep warm.
  module Renderer
    # Lookup prefix for slash-less partial references. The grammar only emits
    # slash-qualified refs ("t42/p1"), so this is a safety net, not a feature.
    PREFIX = "fuzz"

    # json.cache!/cache_if! ask @context.controller.perform_caching before
    # touching Rails.cache; with caching off they just yield.
    CACHING_DISABLED_CONTROLLER = Struct.new(:perform_caching).new(false)

    module_function

    def render(views_root:, template:, ivars:, helpers: {})
      lookup = ActionView::LookupContext.new(
        [views_root.to_s], {formats: [:json], handlers: [:jbuilder]}, [PREFIX]
      )
      # with_empty_template_cache returns a FRESH view subclass per call, so
      # per-seed helper methods never leak across renders.
      view_class = ActionView::Base.with_empty_template_cache
      helpers.each { |name, value| view_class.define_method(name) { value } }
      view = view_class.with_context(lookup, ivars.dup, CACHING_DISABLED_CONTROLLER)
      JSON.parse(lookup.find_template(template, [], false).render(view, {}).to_s)
    end
  end
end
