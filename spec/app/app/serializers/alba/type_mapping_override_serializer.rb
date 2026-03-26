# frozen_string_literal: true

module Alba
  class TypeMappingOverrideSerializer < BaseSerializer
    typelize_from ::User

    # Override decimal to string (e.g. PostgreSQL numeric → BigDecimal → JSON string)
    typelizer_config.type_mapping = Typelizer::TYPE_MAPPING.merge(decimal: :string)

    attributes :attr_decimal, :attr_float, :attr_integer, :attr_date
  end
end
