# FROZEN CONTRACT fixture (see spec/typelizer/jbuilder_inertia_contract_spec.rb).
# Resolver-object form: `JbuilderInertia.<constructor> { ... }` as the prop
# VALUE. Resolver blocks contain arbitrary Ruby returning a plain value (NOT
# jbuilder DSL); type inference reads the block's final expression when it's
# a recognizable literal/Time pattern, otherwise falls through to model
# columns and name hints. Only defer/optional widen.
typelize_as "ContractResolverForms"
typelize_from User

json.deferred_amount JbuilderInertia.defer { 42 }
json.optional_flag JbuilderInertia.optional { true }
json.deferred_grouped JbuilderInertia.defer(group: "stats") { {sum: 1} }
json.fetched_at JbuilderInertia.defer { Time.current }
json.likes_count JbuilderInertia.defer { compute_likes }
json.name JbuilderInertia.defer { expensive_name_lookup }
json.merged_tag JbuilderInertia.merge { "tag" }
json.deep_merged_meta JbuilderInertia.deep_merge { {a: 1} }
json.once_token ::JbuilderInertia.once { "tok" }
json.always_label JbuilderInertia.always { "label" }
json.scroll_cursor JbuilderInertia.scroll { "cursor" }
