# Dynamic/unsupported forms — the walker drops them silently rather than
# fabricate types. Use typelize: to pin the shape when you need one.

json.known "value"

# Skipped (dynamic hash) — no property emitted.
json.merge! some_runtime_hash

# Skipped (dynamic key) — no property emitted.
json.set! dynamic_key, some_value

# Pin the shape with typelize: when you know it.
json.runtime_data typelize: "Record<string, unknown>"

# Skipped (runtime mutation) — has no static effect.
json.null!
json.key_format! camelize: :lower
