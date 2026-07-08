# frozen_string_literal: true

module Typelizer
  module TypeInference
    private

    def apply_model_inference(prop)
      # A union carrying delegated members resolves per-member in
      # `resolve_deferred_members`; whole-prop inference here would overwrite
      # the union with the sole column type.
      return prop if deferred_union?(prop)

      model_plugin.infer_types(prop)
    end

    def apply_metadata(prop)
      # Column metadata (enum, comment) describes ONE member of a
      # deferred-member union, not the union — an enum in particular would
      # repaint the whole property as the enum type.
      return prop if deferred_union?(prop)

      prop.tap do |p|
        p.comment ||= model_plugin.comment_for(p) if config.comments && p.comment != false
        p.enum ||= model_plugin.enum_for(p) if p.enum != false
      end
    end

    # A union type containing walker-delegated members (see the jbuilder
    # Walker's `DeferredInference`) — duck-typed so this eager-loaded module
    # never references that lazily-loaded class.
    def deferred_union?(prop)
      prop.type.is_a?(Array) && prop.type.any? { |m| m.respond_to?(:typelizer_deferred_inference?) }
    end

    # Resolves delegated union members: each marker gets the same per-column
    # model inference a sole nil-typed property would (via a probe property),
    # its member becomes the inferred type — and the property's
    # nullability/optionality widen by the column's, since the delegated
    # occurrence renders the column value. Members inference can't fill
    # become "unknown", which the serializer plugin's post-inference warning
    # reports. Runs unconditionally in `infer_nested_property_types`, so
    # markers are resolved before Interface-level consumers see the type —
    # even for user-asserted or DSL-typed properties that skip whole-prop
    # inference.
    def resolve_deferred_members(prop)
      return prop unless deferred_union?(prop)

      nullable = prop.nullable
      optional = prop.optional
      members = prop.type.map do |member|
        next member unless member.respond_to?(:typelizer_deferred_inference?)

        probe = model_plugin.infer_types(
          Property.new(name: member.column_name, column_name: member.column_name,
            optional: false, nullable: false, multi: false)
        )
        nullable ||= probe.nullable
        optional ||= probe.optional
        member.resolved_member(probe)
      end.uniq

      # A single surviving member folds back to the plain representation
      # (mirroring the walker's own union fold); an array-wrapper member
      # unwraps onto the `multi` flag.
      type, multi =
        if members.size > 1
          [members, prop.multi]
        elsif members.first.respond_to?(:typelizer_array_wrapper?) && members.first.typelizer_array_wrapper?
          [members.first.element, true]
        else
          [members.first, prop.multi]
        end
      prop.with(type: type, multi: multi, nullable: nullable, optional: optional)
    end

    def transform_properties(props)
      return props unless config.properties_transformer

      props = config.properties_transformer.call(props)
      props.map do |prop|
        map_property_shapes(prop) { |shape| Shape.new(properties: transform_properties(shape.properties)) }
      end
    end

    def infer_nested_property_types(prop)
      prop = resolve_deferred_members(prop)
      map_property_shapes(prop) { |shape| infer_shape_types(shape) }
    end

    # Inline `Shape`s appear as a property's own type, as trailing
    # intersection members (`additional_types`, e.g. a jbuilder mixed
    # composed-partial block), as members of a union (Array type, e.g. a
    # jbuilder conditional re-set), and as elements of an array wrapper —
    # applies the block to every Shape in all positions so transformation
    # and inference run through the same walk.
    def map_property_shapes(prop, &block)
      if prop.additional_types&.any?(Shape)
        prop = prop.with(additional_types: prop.additional_types.map { |t|
          t.is_a?(Shape) ? yield(t) : t
        })
      end

      case prop.type
      when Shape
        prop.with(type: yield(prop.type))
      when Array
        prop.with(type: prop.type.map { |member| map_shape_member(member, &block) })
      else
        return prop unless prop.type.respond_to?(:map_element_shape)

        prop.with(type: prop.type.map_element_shape(&block))
      end
    end

    # A union member (or a sole type) is an inline Shape, an array wrapper
    # whose element may hold Shapes (duck-typed via `map_element_shape` —
    # the jbuilder walker's lazily-loaded `ArrayOf`), or an opaque type left
    # as-is.
    def map_shape_member(member, &block)
      case member
      when Shape then yield member
      else member.respond_to?(:map_element_shape) ? member.map_element_shape(&block) : member
      end
    end

    def infer_shape_types(shape)
      shape.map_properties do |sub_prop|
        sub_prop
          # Same class-name resolution the top-level pipeline runs, so a
          # nested `typelize: "SomeSerializer"` resolves to an interface
          # reference instead of surviving as a literal (which renders as-is
          # and emits a dangling import). `resolve_asserted_type` lives on
          # Interface; duck-typed includers of this module (Alba's
          # TraitInterface) never carry user_asserted props, so skip it there.
          .then { |p| respond_to?(:resolve_asserted_type, true) ? resolve_asserted_type(p) : p }
          .then { |p| p.type ? p : apply_model_inference(p) }
          .then { |p| p.inference_locked ? p : apply_metadata(p) }
          .then { |p| infer_nested_property_types(p) }
      end
    end

    def model_class
      return serializer._typelizer_model_name if serializer.respond_to?(:_typelizer_model_name)

      config.instance_exec(serializer, &config.serializer_model_mapper)
    rescue NameError => e
      Typelizer.logger.debug("model_mapper failed for serializer #{serializer.name}: #{e.class}: #{e.message}")

      nil
    end

    def model_plugin
      @model_plugin ||= config.model_plugin.new(model_class: model_class, config: config)
    end
  end
end
