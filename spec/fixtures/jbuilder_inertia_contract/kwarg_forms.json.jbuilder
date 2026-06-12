# FROZEN CONTRACT fixture (see spec/typelizer/jbuilder_inertia_contract_spec.rb).
# Full `inertia:` kwarg grammar. Vocabulary source of truth:
# JbuilderInertia::PropBuilder::KNOWN_DIRECTIVES — only :defer and :optional widen.
typelize_as "ContractKwargForms"

json.deferred_stats @stats, inertia: :defer
json.optional_stats @stats, inertia: :optional
json.merged_list @list, inertia: :merge
json.always_value @value, inertia: :always
json.once_value @value, inertia: :once
json.scroll_items @items, inertia: :scroll
json.array_widens @stats, inertia: [:defer, :merge]
json.array_keeps @list, inertia: [:merge, :once]
json.hash_widens @stats, inertia: {defer: {group: "dashboard"}}
json.hash_optional_widens @stats, inertia: {optional: {once: true}}
json.hash_keeps @list, inertia: {merge: {match_on: "id"}}
