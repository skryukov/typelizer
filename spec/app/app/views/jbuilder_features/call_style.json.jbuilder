# `json.(record, :a, :b)` — call-style alias for json.extract!

typelize_from Post

json.call(@post, :id, :title, :body)
json.computed "value", typelize: "string"
