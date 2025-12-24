# frozen_string_literal: true

module Alba
  class CommentSerializer < BaseSerializer
    attributes :id, :body

    has_one :parent, resource: CommentSerializer
    has_many :replies, resource: CommentSerializer

    # Test manual self-referencing types
    typelize parent: "AlbaComment?", replies: "AlbaComment[]", body: :string
  end
end
