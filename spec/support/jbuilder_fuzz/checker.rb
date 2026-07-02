# frozen_string_literal: true

module JbuilderFuzz
  # Validates one rendered JSON document against the walker's typed model
  # (Interface#properties / #root_is_array / #root_array_element).
  #
  # SOUNDNESS rules (a violation means the emitted TypeScript type REJECTS
  # what jbuilder actually rendered):
  #   - every rendered key must be covered by a property (:uncovered_key)
  #   - a property with optional:false must be present (:missing_required_key)
  #   - null rendered where nullable:false and the type doesn't cover null
  #     (:null_rejected)
  #   - a value must satisfy the property type; unions need >= 1 matching
  #     member; multi/ArrayOf check every element (:type_mismatch /
  #     :no_union_member)
  #   - `unknown` (and a nil type, which renders as `unknown`) is a wildcard
  #     and accepts anything, including null
  #
  # Warnings are judged by the caller (Runner): an :uncovered_key on a warned
  # template is excused entirely; other violations on a warned template are
  # SEVERITY-B instead of SEVERITY-A.
  module Checker
    Violation = Struct.new(:kind, :path, :detail, keyword_init: true)

    NULL_COVERING_SCALARS = %w[null unknown any].freeze

    module_function

    # model: {properties:, root_is_array:, root_array_element:}
    def check(model, rendered)
      violations = []
      if model[:root_is_array]
        unless rendered.is_a?(Array)
          violations << Violation.new(kind: :type_mismatch, path: "$",
            detail: "emitted type is a root array but render is #{rendered.class}: #{truncate(rendered.inspect)}")
          return violations
        end
        element = model[:root_array_element]
        rendered.each_with_index do |el, i|
          if element.nil?
            check_object(el, model[:properties], "$[#{i}]", violations)
          else
            check_type(el, element, "$[#{i}]", violations)
          end
        end
      else
        check_object(rendered, model[:properties], "$", violations)
      end
      violations
    end

    def check_object(value, properties, path, violations)
      unless value.is_a?(Hash)
        violations << Violation.new(kind: :type_mismatch, path: path,
          detail: "expected an object, got #{truncate(value.inspect)}")
        return
      end

      by_name = {}
      properties.each { |p| by_name[p.name.to_s] = p }

      value.each_key do |key|
        next if by_name.key?(key)
        violations << Violation.new(kind: :uncovered_key, path: "#{path}.#{key}",
          detail: "rendered key #{key.inspect} (= #{truncate(value[key].inspect)}) has no property in the emitted type")
      end

      by_name.each do |name, prop|
        if value.key?(name)
          check_property(value[name], prop, "#{path}.#{name}", violations)
        elsif !prop.optional
          violations << Violation.new(kind: :missing_required_key, path: "#{path}.#{name}",
            detail: "property is required (optional: false) but the key is absent from the render")
        end
      end
    end

    def check_property(value, prop, path, violations)
      if value.nil?
        null_ok = prop.nullable || (!prop.multi && covers_null?(prop.type))
        unless null_ok
          violations << Violation.new(kind: :null_rejected, path: path,
            detail: "render is null but the property is nullable:false with type #{describe(prop.type, multi: prop.multi)}")
        end
        return
      end

      if prop.enum
        # Defensive: grammar v1 never produces enums.
        return if prop.enum.map(&:to_s).include?(value.to_s)
        violations << Violation.new(kind: :type_mismatch, path: path,
          detail: "value #{truncate(value.inspect)} not in enum #{prop.enum.inspect}")
        return
      end

      if prop.multi
        unless value.is_a?(Array)
          violations << Violation.new(kind: :type_mismatch, path: path,
            detail: "expected Array<#{describe(prop.type)}>, got #{truncate(value.inspect)}")
          return
        end
        value.each_with_index { |el, i| check_type(el, prop.type, "#{path}[#{i}]", violations) }
        return
      end

      check_type(value, prop.type, path, violations)
      # Intersection members must ALL accept (defensive; not in grammar v1).
      Array(prop.additional_types).each { |member| check_type(value, member, path, violations) }
    end

    def check_type(value, type, path, violations)
      case type
      when nil
        # Delegated/unresolved type renders as `unknown` — wildcard.
      when Array
        check_union(value, type, path, violations)
      when Typelizer::Shape
        check_object(value, type.properties, path, violations)
      when String, Symbol
        unless scalar_ok?(type.to_s, value)
          violations << Violation.new(kind: value.nil? ? :null_rejected : :type_mismatch, path: path,
            detail: "expected #{type}, got #{truncate(value.inspect)}")
        end
      else
        if type.respond_to?(:element) # the walker's ArrayOf
          unless value.is_a?(Array)
            violations << Violation.new(kind: :type_mismatch, path: path,
              detail: "expected #{describe(type)}, got #{truncate(value.inspect)}")
            return
          end
          value.each_with_index { |el, i| check_type(el, type.element, "#{path}[#{i}]", violations) }
        elsif type.respond_to?(:properties) # Interface-like
          check_object(value, type.properties, path, violations)
        end
        # Anything else is accepted conservatively (no false alarms).
      end
    end

    # Union: the value must satisfy at least one member. If every member
    # rejects, but some member fails ONLY on key coverage, surface those
    # coverage violations (the value structurally fits that member).
    def check_union(value, members, path, violations)
      probes = members.map do |member|
        probe = []
        check_type(value, member, path, probe)
        probe
      end
      return if probes.any?(&:empty?)

      coverage_only = probes.select { |probe| probe.all? { |v| v.kind == :uncovered_key } }
      if coverage_only.any?
        violations.concat(coverage_only.min_by(&:size))
      else
        violations << Violation.new(kind: :no_union_member, path: path,
          detail: "render #{truncate(value.inspect)} matches no member of the union #{describe(members)}")
      end
    end

    def covers_null?(type)
      case type
      when nil then true
      when String, Symbol then NULL_COVERING_SCALARS.include?(type.to_s)
      when Array then type.any? { |member| covers_null?(member) }
      else false
      end
    end

    def scalar_ok?(type, value)
      case type
      when "string" then value.is_a?(String)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      when "unknown", "any" then true
      else true # unrecognized scalar type names: accept conservatively
      end
    end

    def describe(type, multi: false)
      str =
        case type
        when nil then "unknown"
        when Array then type.map { |member| describe(member) }.join(" | ")
        when Typelizer::Shape then type.to_s.gsub(/\s+/, " ")
        when String, Symbol then type.to_s
        else
          if type.respond_to?(:element)
            "Array<#{describe(type.element)}>"
          elsif type.respond_to?(:name)
            type.name.to_s
          else
            type.to_s
          end
        end
      multi ? "Array<#{str}>" : str
    end

    def truncate(str, max = 200)
      (str.length > max) ? "#{str[0, max]}…" : str
    end
  end
end
