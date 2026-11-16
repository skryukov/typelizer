# frozen_string_literal: true

module Panko
  # Attributes and associations excluded by a class-level `filters_for` are not generated
  class FiltersSerializer < BaseSerializer
    typelize_from ::User

    attributes :id, :username, :name

    has_many :posts, serializer: PostSerializer
    has_one :invitor, serializer: UserSerializer

    def self.filters_for(_context, _scope)
      {except: [:name, :posts]}
    end
  end
end
