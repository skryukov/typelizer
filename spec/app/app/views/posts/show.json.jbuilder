json.partial! "posts/post", post: @post
json.author do
  json.partial! "users/user", user: @post.user
end
json.summary @post.body, typelize: "string"
