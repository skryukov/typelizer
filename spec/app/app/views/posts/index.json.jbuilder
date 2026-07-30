json.title "Posts"
json.total_count @posts.count
json.posts @posts, partial: "posts/post", as: :post
