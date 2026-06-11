# `json.items @items do |item| ... end` — collection iteration with block
# params yields an array of the element shape.

json.posts @posts do |post|
  json.id post.id
  json.title post.title, typelize: "string"
end
