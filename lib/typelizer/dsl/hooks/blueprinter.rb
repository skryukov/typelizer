# frozen_string_literal: true

module Typelizer
  module DSL
    module Hooks
      module Blueprinter
        include Methods
        extend Builder

        hook :field, :identifier, :association
      end
    end
  end
end
