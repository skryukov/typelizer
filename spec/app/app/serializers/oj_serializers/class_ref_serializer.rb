# frozen_string_literal: true

module OjSerializers
  class ClassRefSerializer < BaseSerializer
    typelize_from ::Post

    attributes :id, :title

    # Test: typelize with a serializer class constant resolves to $ref in OpenAPI
    attribute :reviewer
    typelize reviewer: [UserSerializer, {optional: true, nullable: true}]

    # Test: typelize with a serializer class name string resolves to $ref in OpenAPI
    attribute :editor
    typelize editor: "OjSerializers::UserSerializer"

    # Test: typelize with "Serializer | null" extracts nullable and resolves the class
    attribute :approver
    typelize approver: "OjSerializers::UserSerializer | null"

    # Test: typelize with union of two serializer classes generates anyOf in OpenAPI
    attribute :commentable
    typelize commentable: "OjSerializers::UserSerializer | OjSerializers::CommentSerializer"

    # Test: typelize with mixed class constants in union
    attribute :mixed_ref
    typelize mixed_ref: [UserSerializer, CommentSerializer]

    # Test: nullable array of refs — nullable applies to array, not items
    attribute :contributors
    typelize contributors: [UserSerializer, {multi: true, nullable: true}]
  end
end
