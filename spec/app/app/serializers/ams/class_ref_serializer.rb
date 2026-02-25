# frozen_string_literal: true

module Ams
  class ClassRefSerializer < BaseSerializer
    typelize_from ::Post

    attributes :id, :title

    # Test: typelize with a serializer class constant resolves to $ref in OpenAPI
    attribute :reviewer
    typelize reviewer: [UserSerializer, {optional: true, nullable: true}]

    # Test: typelize with a serializer class name string resolves to $ref in OpenAPI
    attribute :editor
    typelize editor: "Ams::UserSerializer"

    # Test: typelize with "Serializer | null" extracts nullable and resolves the class
    attribute :approver
    typelize approver: "Ams::UserSerializer | null"

    # Test: typelize with union of two serializer classes generates anyOf in OpenAPI
    attribute :commentable
    typelize commentable: ["Ams::UserSerializer", "Ams::CommentSerializer"]

    # Test: typelize with mixed string and class constant in union
    attribute :mixed_ref
    typelize mixed_ref: ["Ams::UserSerializer", CommentSerializer]
  end
end
