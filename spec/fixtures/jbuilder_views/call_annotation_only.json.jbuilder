# `json.(...)` with annotation-only kwargs and a block: after stripping,
# upstream `call` has no default for its object param (unlike `array!`), so
# SetExt forwards an empty collection — the template renders `[]`.
json.call(typelize: "number[]") do |item|
  json.id item
end
