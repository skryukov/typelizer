# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # A rendered array type for the spots where the Property-level `multi`
        # flag can't express array-ness: one side of a re-set union (an array
        # block conditionally re-set with a scalar renders
        # `Array<X> | string`, never `Array<X | string>`) and the element of
        # a nested array (`json.child!` inside a collection-value block —
        # `Array<Array<X>>`). Renders as `Array<element>` via `to_s`;
        # `map_element_shape` lets type inference and the post-inference
        # unknown warning recurse into a Shape element the same way they walk
        # plain Shape members (duck-typed, so nothing eager-loaded needs this
        # lazily-loaded class).
        class ArrayOf
          attr_reader :element

          def initialize(element)
            @element = element
            freeze
          end

          # How eager-loaded consumers (Interface, OpenAPI, TypeInference)
          # detect this wrapper without referencing the lazily-loaded class
          # (same marker pattern as `typelizer_deferred_inference?`).
          def typelizer_array_wrapper?
            true
          end

          # Recursive: a nested wrapper (`ArrayOf(ArrayOf(Shape))`, from
          # `json.child!` inside a collection-value block folded into a
          # union) must still expose its inner Shapes to type inference and
          # the post-inference unknown warning.
          def map_element_shape(&block)
            self.class.new(map_member(element, &block))
          end

          def to_s
            members = element.is_a?(Array) ? element : [element]
            "Array<#{members.map { |m| render_member(m) }.join(" | ")}>"
          end

          def ==(other)
            other.is_a?(self.class) && element == other.element
          end
          alias_method :eql?, :==

          def hash
            [self.class, element].hash
          end

          private

          # Kept as the walker's own cascade instead of delegating to
          # TypeTraversal.map_shapes: the coverage ratchet pins these
          # branches, and its floor may only ratchet upward.
          def map_member(member, &block)
            case member
            when Shape then yield member
            when Array then member.map { |m| map_member(m, &block) }
            when self.class then member.map_element_shape(&block)
            else member
            end
          end

          def render_member(member)
            case member
            when Shape then member.to_s
            when nil then "unknown"
            else member.respond_to?(:name) ? member.name : member.to_s
            end
          end
        end
      end
    end
  end
end
