# frozen_string_literal: true

module Panko
  class ClassRefSerializer < BaseSerializer
    typelize_from ::Post

    attributes :id, :title

    # Test: typelize with a serializer class constant resolves to $ref in OpenAPI
    attributes :reviewer
    typelize reviewer: [UserSerializer, {optional: true, nullable: true}]

    # Test: typelize with a serializer class name string resolves to $ref in OpenAPI
    attributes :editor
    typelize editor: "Panko::UserSerializer"

    # Test: typelize with "Serializer | null" extracts nullable and resolves the class
    attributes :approver
    typelize approver: "Panko::UserSerializer | null"

    # Test: typelize with union of two serializer classes generates anyOf in OpenAPI
    attributes :commentable
    typelize commentable: "Panko::UserSerializer | Panko::CommentSerializer"

    # Test: typelize with mixed class constants in union
    attributes :mixed_ref
    typelize mixed_ref: [UserSerializer, CommentSerializer]

    # Test: nullable array of refs — nullable applies to array, not items
    attributes :contributors
    typelize contributors: [UserSerializer, {multi: true, nullable: true}]
  end
end
