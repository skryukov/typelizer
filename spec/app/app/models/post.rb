class Post < ApplicationRecord
  belongs_to :user

  enum category: %i[news article blog].index_by(&:itself)

  def next_post
    # Returns Post
  end
end
