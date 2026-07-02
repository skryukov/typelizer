# Blockless named-element root array: `json.array! @xs, partial:, as:`
# resolves the element to the partial's NAMED interface, so the OpenAPI
# writer emits `{type: :array, items: {"$ref" => ...JbuilderFeaturesWidget}}`
# — exercised inside the full validated document
# (spec/openapi_validation_spec.rb) for both 3.0 and 3.1 dialects.
# Discovered like every other fixture through the app-wide
# `config.jbuilder_views = [app/views]` initializer.

json.array! @widgets, partial: "jbuilder_features/widget", as: :widget
