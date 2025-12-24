# frozen_string_literal: true

module Panko
  class SortedSerializer < BaseSerializer
    typelizer_config do |c|
      c.properties_sort_order = :id_first_alphabetical
    end

    typelize_from ::User

    # Properties intentionally out of alphabetical order
    # With sorting: id, active, email, name, username, created_at
    attributes :username, :name, :id, :active, :email, :created_at

    typelize id: [:string, comment: "Unique identifier"]
    def id
      Base64.urlsafe_encode64(object.id.to_s)
    end

    typelize email: :string
    def email
      "#{object.username}@example.com"
    end

    typelize created_at: :string
    def created_at
      object.created_at&.iso8601
    end
  end
end
