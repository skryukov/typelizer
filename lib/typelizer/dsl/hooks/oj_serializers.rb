# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      module OjSerializers
        include Methods
        extend Builder

        hook :attribute, :has_one, :belongs_to, :flat_one
        hook :has_many, multi: true
      end
    end
  end
end
