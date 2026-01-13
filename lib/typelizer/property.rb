module Typelizer
  Property = Struct.new(
    :name, :type, :optional, :nullable,
    :multi, :column_name, :comment, :enum, :enum_type_name, :deprecated,
    :with_traits,
    keyword_init: true
  ) do
    def inspect
      props = to_h.merge(type: type_name).map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "<#{self.class.name} #{props}>"
    end

    def eql?(other)
      return false unless other.is_a?(self.class)

      fingerprint == other.fingerprint
    end

    def to_s
      type_str = type_name

      # Handle intersection types for traits
      if with_traits&.any? && type.respond_to?(:name)
        trait_types = with_traits.map { |t| "#{type.name}#{t.to_s.camelize}Trait" }
        type_str = ([type_str] + trait_types).join(" & ")
      end

      type_str = "Array<#{type_str}>" if multi
      type_str = "#{type_str} | null" if nullable

      "#{name}#{"?" if optional}: #{type_str}"
    end

    def fingerprint
      props = to_h
      props[:type] = type_name
      props.each_with_object(+"<#{self.class.name}") do |(k, v), fp|
        fp << " #{k}=#{v.inspect}" unless v.nil?
      end << ">"
    end

    def enum_definition
      return unless enum && enum_type_name

      "type #{enum_type_name} = #{enum.map { |v| v.to_s.inspect }.join(" | ")}"
    end

    private

    def type_name
      return enum_type_name if enum_type_name

      type.respond_to?(:name) ? type.name : type || "unknown"
    end
  end
end
