class Post < ApplicationRecord
  include UserDelegatable

  belongs_to :user, optional: true

  enum category: {news: 1, article: 2, blog: 3}

  delegate :name, to: :user, allow_nil: true
  delegate :username, to: :user, prefix: true
  delegate :active, to: :user, prefix: :author

  def next_post
    # Returns Post
  end

  def previous_post
    # Returns Post
  end
end
