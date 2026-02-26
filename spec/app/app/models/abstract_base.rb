class AbstractBase < ApplicationRecord
  self.abstract_class = true

  attribute :custom_attr, :string
end
