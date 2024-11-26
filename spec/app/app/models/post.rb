class Post < ApplicationRecord
  belongs_to :user

  enum category: {news: 1, article: 2, blog: 3}

  def next_post
    # Returns Post
  end
end
