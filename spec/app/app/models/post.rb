class Post < ApplicationRecord
  belongs_to :user

  enum category: [:news, :article, :blog].index_by(&:itself)
end
