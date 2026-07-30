# if/unless wrapping → properties emerge as optional keys.

json.always "value"

if @feature_flag
  json.featured true
  json.badge "hot", typelize: "string"
end

unless @hidden
  json.public_id 42, typelize: "number"
end
