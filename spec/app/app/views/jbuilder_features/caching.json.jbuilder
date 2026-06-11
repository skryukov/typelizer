# json.cache! / cache_if! / cache_root! are transparent — their blocks walk
# normally and the cache framing emits nothing.

json.cache! @post, expires_in: 1.hour do
  json.title @post.title, typelize: "string"
  json.body @post.body, typelize: "string"
end

json.meta do
  json.cache_if! @post.published_at, ["meta", @post] do
    json.rendered_at Time.current
  end
end
