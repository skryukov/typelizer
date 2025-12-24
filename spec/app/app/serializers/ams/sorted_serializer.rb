# frozen_string_literal: true

module Ams
  class SortedSerializer < BaseSerializer
    typelizer_config do |c|
      c.properties_sort_order = :id_first_alphabetical
    end

    typelize_from ::User

    # Properties intentionally out of alphabetical order
    # With sorting: id, active, email, name, username, created_at
    attributes :username, :name, :id, :active

    typelize email: :string
    attribute :email do
      "#{object.username}@example.com"
    end

    typelize created_at: :string
    attribute :created_at do
      object.created_at&.iso8601
    end
  end
end
