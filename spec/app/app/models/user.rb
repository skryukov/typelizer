class User < ApplicationRecord
  belongs_to :invitor, class_name: "User"

  has_many :friends, class_name: "User", foreign_key: :invitor_id
  has_many :posts
  has_one :latest_post, class_name: "Post", foreign_key: :user_id, required: true
end
