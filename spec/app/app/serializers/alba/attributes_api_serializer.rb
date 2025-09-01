module Alba
  class AttributesApiSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :attr_string, :attr_integer,
      :attr_float, :attr_boolean, :attr_datetime,
      :attr_date, :attr_time, :attr_json,
      :attr_array, :attr_range
  end
end
