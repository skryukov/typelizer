# `inertia: :defer` interacting with branch merging — the deferred prop is
# optional exactly once, regardless of which branch carries the kwarg.

json.title "Stats"

if @full
  json.stats @data, inertia: :defer, typelize: "Record<string, number>"
else
  json.stats nil, typelize: "Record<string, number>"
end

if @cheap
  json.metrics nil, typelize: "Record<string, number>"
else
  json.metrics @metrics, inertia: :defer, typelize: "Record<string, number>"
end
