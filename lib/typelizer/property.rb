module Typelizer
  Property = Struct.new(
    :name, :type, :optional, :nullable,
    :multi, :column_name, :comment, :enum, :deprecated,
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
      type_str = "Array<#{type_str}>" if multi
      type_str = "#{type_str} | null" if nullable

      "#{name}#{"?" if optional}: #{type_str}"
    end

    def fingerprint
      props = to_h.merge(type: type_name).reject { |_, v| v.nil? }.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "<#{self.class.name} #{props}>"
    end

    private

    def type_name
      return enum.map { |v| v.to_s.inspect }.join(" | ") if enum

      type.respond_to?(:name) ? type.name : type || "unknown"
    end
  end
end
