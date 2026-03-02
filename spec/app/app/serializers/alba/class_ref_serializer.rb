# frozen_string_literal: true

module Alba
  class ClassRefSerializer < BaseSerializer
    typelize_from ::Post

    attributes :id, :title

    # Test: typelize with a serializer class constant resolves to $ref in OpenAPI
    attributes :reviewer
    typelize reviewer: [UserSerializer, {optional: true, nullable: true}]

    # Test: typelize with a serializer class name string resolves to $ref in OpenAPI
    attributes :editor
    typelize editor: "Alba::UserSerializer"

    # Test: typelize with "Serializer | null" extracts nullable and resolves the class
    attributes :approver
    typelize approver: "Alba::UserSerializer | null"

    # Test: typelize with union of two serializer classes generates anyOf in OpenAPI
    attributes :commentable
    typelize commentable: "Alba::UserSerializer | Alba::CommentSerializer"

    # Test: typelize with mixed class constants in union
    attributes :mixed_ref
    typelize mixed_ref: [UserSerializer, CommentSerializer]

    # Test: nullable array of refs — nullable applies to array, not items
    attributes :contributors
    typelize contributors: [UserSerializer, {multi: true, nullable: true}]
  end
end
