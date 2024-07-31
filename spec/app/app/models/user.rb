class User < ApplicationRecord
  belongs_to :invitor, class_name: "User", optional: true
end
