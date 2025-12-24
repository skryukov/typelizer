# frozen_string_literal: true

module Ams
  class CommentSerializer < BaseSerializer
    attributes :id, :body

    belongs_to :parent, serializer: CommentSerializer
    has_many :replies, serializer: CommentSerializer

    # Test manual self-referencing types
    typelize parent: "AmsComment?", replies: "AmsComment[]", body: :string
  end
end
