# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Jbuilder
      class Walker
        # A union member whose type is delegated to model inference: an
        # occurrence the walker folded in with `type: nil` (an `extract!`-ed
        # column unioned with, say, a conditional literal). Dropping it (or
        # locking the merged prop) silently narrowed the union to the literal
        # side — the column's real type must survive.
        #
        # INTERNAL ONLY: `TypeInference#resolve_deferred_members` (which we
        # also own) replaces every marker with the model-inferred column type
        # before `Interface`-level consumers (render, imports, fingerprint,
        # OpenAPI) ever see the property, honoring the union-member contract
        # (String/Symbol/Shape/ArrayOf/Interface). The duck method
        # `typelizer_deferred_inference?` is how that eager-loaded module
        # detects markers without referencing this lazily-loaded class;
        # `to_s` is a pure safety net.
        class DeferredInference
          attr_reader :column_name

          def initialize(column_name)
            @column_name = column_name.to_s
            freeze
          end

          def typelizer_deferred_inference?
            true
          end

          # Maps the model-inferred probe property back to a contract-safe
          # union member: the column type (array columns keep their wrapper),
          # or "unknown" when inference came up empty — the plugin's
          # post-inference warning picks those up.
          def resolved_member(probe)
            type = probe.type
            return "unknown" if type.nil?

            type = type.to_s if type.is_a?(Symbol)
            probe.multi ? ArrayOf.new(type) : type
          end

          def ==(other)
            other.is_a?(self.class) && column_name == other.column_name
          end
          alias_method :eql?, :==

          def hash
            [self.class, column_name].hash
          end

          def to_s
            "unknown"
          end
        end
      end
    end
  end
end
