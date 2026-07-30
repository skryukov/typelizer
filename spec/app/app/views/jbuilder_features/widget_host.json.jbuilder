# `json.partial! "widget"` — a bare partial name resolves against the
# current template's directory first (Rails partial-lookup semantics),
# before falling back to a views_root-relative path.

json.partial! "widget"
json.host_only true
