# Full AR column-type matrix — the User model pre-declares every AR
# attribute type. Verifies the jbuilder plugin routes through Typelizer's
# existing AR model inference for type mapping.

typelize_from User

json.extract! @user,
  :id, :name, :username, :active, :role,
  :attr_string, :attr_integer, :attr_float, :attr_boolean,
  :attr_datetime, :attr_date, :attr_time, :attr_json,
  :attr_array, :attr_decimal, :attr_range
