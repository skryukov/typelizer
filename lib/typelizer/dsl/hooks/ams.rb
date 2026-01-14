# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      module AMS
        include Methods
        extend Builder

        hook :attribute, :has_one, :belongs_to
        hook :has_many, multi: true
      end
    end
  end
end
