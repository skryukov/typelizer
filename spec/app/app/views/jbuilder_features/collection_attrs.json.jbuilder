# `json.items @items, :a, :b` — collection + attr shortcut, no partial.

typelize_from Post

json.posts @posts, :id, :title, :published_at
