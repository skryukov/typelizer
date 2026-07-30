# `json.array! @items do |item| ... end` at template root emits the whole
# interface as `Array<FooData>`, using Typelizer's `root_is_array` hook
# (mirrors the existing `root_key` wrapping mechanism).

json.array! @items do |item|
  json.id item.id
  json.name item.name, typelize: "string"
end
