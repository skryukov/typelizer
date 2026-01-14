# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      module Panko
        include Methods
        extend Builder

        hook :has_one
        hook :has_many, multi: true
        hook_method_added
      end
    end
  end
end
