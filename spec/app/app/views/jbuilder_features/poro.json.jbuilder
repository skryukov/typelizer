# No model binding, no typelize overrides — falls back to name heuristics
# where possible, `unknown` otherwise. Warnings surface to dev logs.

json.opaque @obj.some_method
json.count @items.size
json.is_active @obj.flag
json.created_at Time.current
