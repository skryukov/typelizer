# frozen_string_literal: true

module Typelizer
  # The one place that knows the member vocabulary of a Property#type:
  # a leaf (String/Symbol name, named Interface, nil), an inline Shape,
  # a union (Array of members — the walker's same-level fold), or the
  # jbuilder walker's lazy ArrayOf wrapper (matched by its
  # typelizer_array_wrapper? marker, so nothing here references that
  # lazily-loaded class). Consumers that walk a type tree — import and
  # enum collection, nested inference, shape transformation, unknown
  # warnings — go through these traversals instead of re-deriving the
  # case-cascade at every site.
  module TypeTraversal
    module_function

    # The jbuilder walker's lazy array wrapper, matched by its marker — it
    # lives in a lazily-loaded plugin file, so no constant reference from
    # here. Calling the marker (not bare respond_to?) keeps its body
    # executed under the walker coverage ratchet.
    def array_wrapper?(type)
      type.respond_to?(:typelizer_array_wrapper?) && type.typelizer_array_wrapper?
    end

    # Yields every inline Shape reachable through unions and array
    # wrappers. Read-only companion of #map_shapes.
    def each_shape(type, &block)
      case type
      when Shape then yield type
      when Array then type.each { |member| each_shape(member, &block) }
      else
        each_shape(type.element, &block) if array_wrapper?(type)
      end
      nil
    end

    # Structure-preserving rewrite: applies the block to every reachable
    # inline Shape, rebuilding unions and array wrappers around the
    # results. Leaves (named types, nil) pass through as the same object,
    # so callers can cheaply detect "nothing changed" via #equal?.
    def map_shapes(type, &block)
      case type
      when Shape then yield type
      when Array then type.map { |member| map_shapes(member, &block) }
      else
        array_wrapper?(type) ? type.map_element_shape(&block) : type
      end
    end

    # Leaf members reachable through unions and array wrappers: inline
    # Shapes, named Interfaces, and plain String/Symbol type names, in
    # traversal order. Shapes are leaves here — their nested properties
    # are walked structurally via #nested_properties, never tokenized.
    def flat_members(type)
      case type
      when Array then type.flat_map { |member| flat_members(member) }
      else
        array_wrapper?(type) ? flat_members(type.element) : [type]
      end
    end

    # Properties nested under a type: an inline Shape's, or an inline
    # (anonymous) Interface's. Named Interfaces own their properties —
    # they yield nothing here.
    def nested_properties(type)
      flat_members(type).flat_map do |member|
        case member
        when Shape then member.properties
        when Interface then member.inline? ? member.properties : []
        else []
        end
      end
    end
  end
end
