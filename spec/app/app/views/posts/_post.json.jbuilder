typelize_from Post

json.extract! post, :id, :title, :body, :published_at
json.category post.category, typelize: "'news' | 'article' | 'blog'"
