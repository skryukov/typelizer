# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      module Alba
        include Methods
        extend Builder

        hook :attribute, :association, :one, :has_one
        hook :nested_attribute, :nested, :meta
        hook :many, :has_many, multi: true
        hook_method_added
      end
    end
  end
end
