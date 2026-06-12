# FROZEN CONTRACT fixture (see spec/typelizer/jbuilder_inertia_contract_spec.rb).
# `typelize:` asserts the type; inertia widening still applies on top — both
# for the kwarg form and the resolver-object form. Non-widening directives
# leave the asserted property required.
typelize_as "ContractPrecedence"

json.stats @stats, inertia: :defer, typelize: "Record<string, number>"
json.metrics JbuilderInertia.defer { compute_metrics }, typelize: "Record<string, number>"
json.eager_tags @tags, inertia: :merge, typelize: "string[]"
