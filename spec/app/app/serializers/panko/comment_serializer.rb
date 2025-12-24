# frozen_string_literal: true

module Panko
  class CommentSerializer < BaseSerializer
    attributes :id, :body

    has_one :parent, serializer: CommentSerializer
    has_many :replies, serializer: CommentSerializer

    # Test manual self-referencing types
    typelize parent: "PankoComment?", replies: "PankoComment[]", body: :string
  end
end
