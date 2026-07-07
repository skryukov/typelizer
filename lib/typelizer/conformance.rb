# frozen_string_literal: true

module Typelizer
  # Runtime conformance checking: validate a rendered JSON payload against
  # the interface Typelizer emitted for it. This is the "types don't lie"
  # instrument — run it in test mode and every response your suite renders
  # becomes a differential check of the generated types against real data.
  #
  # Serializer-agnostic core: takes any Typelizer::Interface and a parsed
  # JSON document. For jbuilder templates, `Typelizer::Jbuilder::Conformance`
  # (below) maps rendered templates to their interfaces automatically.
  #
  # Soundness rules (a violation means the emitted type REJECTS what was
  # actually rendered):
  #   - every rendered key must be covered by a property
  #   - a property with optional:false must be present
  #   - null rendered where the property is nullable:false and the type
  #     doesn't cover null
  #   - values must satisfy the property type; unions need >= 1 matching
  #     member; intersections check coverage against the UNION of members
  #     and required/type per member; `unknown`/`any` accept anything
  #   - unrecognized scalar type names (inline shapes, TS literal types,
  #     mapped custom types) are accepted conservatively — no false alarms
  module Conformance
    Violation = Struct.new(:kind, :path, :detail, keyword_init: true) do
      def to_s
        "[#{kind}] at #{path}: #{detail}"
      end
    end

    class Mismatch < Typelizer::Error
      attr_reader :violations

      def initialize(message, violations)
        @violations = violations
        super(message)
      end
    end

    NULL_COVERING_SCALARS = %w[null unknown any].freeze

    module_function

    def check(interface, rendered)
      violations = []
      if interface.respond_to?(:root_is_array) && interface.root_is_array
        unless rendered.is_a?(Array)
          violations << Violation.new(kind: :type_mismatch, path: "$",
            detail: "type is a root array but the render is #{rendered.class}: #{truncate(rendered.inspect)}")
          return violations
        end
        element = interface.respond_to?(:root_array_element) ? interface.root_array_element : nil
        rendered.each_with_index do |el, i|
          if element.nil?
            check_object(el, interface.properties, "$[#{i}]", violations)
          else
            check_type(el, element, "$[#{i}]", violations)
          end
        end
      else
        check_object(rendered, interface.properties, "$", violations)
      end
      violations
    end

    def check!(interface, rendered, source: nil)
      violations = check(interface, rendered)
      return true if violations.empty?

      name = interface.respond_to?(:name) ? interface.name : interface.to_s
      header = "rendered JSON does not conform to the emitted type #{name}"
      header += " (#{source})" if source
      raise Mismatch.new("#{header}:\n  #{violations.map(&:to_s).join("\n  ")}", violations)
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
        return if prop.enum.map(&:to_s).include?(value.to_s)
        violations << Violation.new(kind: :type_mismatch, path: path,
          detail: "value #{truncate(value.inspect)} not in enum #{prop.enum.inspect}")
        return
      end

      additionals = prop.respond_to?(:additional_types) ? Array(prop.additional_types) : []

      if prop.multi
        unless value.is_a?(Array)
          violations << Violation.new(kind: :type_mismatch, path: path,
            detail: "expected Array<#{describe(prop.type)}>, got #{truncate(value.inspect)}")
          return
        end
        value.each_with_index do |el, i|
          if additionals.any?
            check_intersection(el, prop.type, additionals, "#{path}[#{i}]", violations)
          else
            check_type(el, prop.type, "#{path}[#{i}]", violations)
          end
        end
        return
      end

      if additionals.any?
        check_intersection(value, prop.type, additionals, path, violations)
      else
        check_type(value, prop.type, path, violations)
      end
    end

    def check_type(value, type, path, violations)
      case type
      when nil
        # Unresolved/delegated type renders as `unknown` — wildcard.
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
        if type.respond_to?(:element) # the jbuilder walker's ArrayOf
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
    # rejects but some fail ONLY on key coverage, surface those coverage
    # violations (the value structurally fits that member).
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

    # Intersection (`base & S1 & S2`): the value must satisfy the base AND
    # every additional member, but key COVERAGE is judged against the UNION
    # of all object-like members.
    def check_intersection(value, base, additionals, path, violations)
      base_members = Array(base).reject { |m| (m.is_a?(String) || m.is_a?(Symbol)) && m.to_s == "null" }
      return if base_members.size > 1 # union-of-many & shapes: accept conservatively

      object_members, scalar_members = (base_members + additionals).partition { |m| object_like?(m) }
      scalar_members.each { |m| check_type(value, m, path, violations) }
      return if object_members.empty?

      unless value.is_a?(Hash)
        violations << Violation.new(kind: :type_mismatch, path: path,
          detail: "expected an object (intersection), got #{truncate(value.inspect)}")
        return
      end

      covered = object_members.flat_map { |m| m.properties.map { |p| p.name.to_s } }
      value.each_key do |key|
        next if covered.include?(key)
        violations << Violation.new(kind: :uncovered_key, path: "#{path}.#{key}",
          detail: "rendered key #{key.inspect} (= #{truncate(value[key].inspect)}) is in no member of the intersection")
      end

      object_members.each do |member|
        member.properties.each do |prop|
          name = prop.name.to_s
          if value.key?(name)
            check_property(value[name], prop, "#{path}.#{name}", violations)
          elsif !prop.optional
            violations << Violation.new(kind: :missing_required_key, path: "#{path}.#{name}",
              detail: "property is required by an intersection member but absent from the render")
          end
        end
      end
    end

    def object_like?(member)
      member.is_a?(Typelizer::Shape) ||
        (!member.is_a?(String) && !member.is_a?(Symbol) && !member.is_a?(Array) &&
          !member.respond_to?(:element) && member.respond_to?(:properties))
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
      else true # inline shapes, literal types, custom mappings: accept conservatively
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
