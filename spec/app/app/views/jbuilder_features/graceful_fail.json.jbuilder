# Dynamic/unsupported forms — the walker skips them rather than fabricate
# types, logging a warning through Typelizer.logger for each dropped
# construct. Use typelize: to pin the shape when you need one.

json.known "value"

# Skipped with a warning (dynamic hash) — no property emitted.
json.merge! some_runtime_hash

# Skipped with a warning (dynamic key) — no property emitted.
json.set! dynamic_key, some_value

# Pin the shape with typelize: when you know it (annotations accompany a
# real value or block — a value-less typelize: warns instead).
json.runtime_data some_runtime_hash, typelize: "Record<string, unknown>"

# Skipped (runtime mutation) — has no static effect.
json.null!
json.key_format! camelize: :lower
