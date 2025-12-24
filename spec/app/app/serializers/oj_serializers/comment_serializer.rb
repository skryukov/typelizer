# frozen_string_literal: true

module OjSerializers
  class CommentSerializer < BaseSerializer
    attributes :id, :body

    has_one :parent, serializer: CommentSerializer
    has_many :replies, serializer: CommentSerializer

    # Test manual self-referencing types
    typelize parent: "OjSerializersComment?", replies: "OjSerializersComment[]", body: :string
  end
end
