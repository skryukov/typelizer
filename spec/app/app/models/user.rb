class User < ApplicationRecord
  belongs_to :invitor, class_name: "User"

  has_many :friends, class_name: "User", foreign_key: :invitor_id
  has_many :posts
  has_one :latest_post, class_name: "Post", foreign_key: :user_id, required: true

  serialize :skills, type: Array, coder: JSON
  serialize :settings, type: Hash, coder: JSON
  serialize :metadata, coder: JSON

  attribute :attr_string, :string
  attribute :attr_integer, :integer
  attribute :attr_float, :float
  attribute :attr_boolean, :boolean
  attribute :attr_datetime, :datetime
  attribute :attr_date, :date
  attribute :attr_time, :time
  attribute :attr_json, :json
  attribute :attr_array, :string, array: true
  attribute :attr_range, :integer, range: true
end
