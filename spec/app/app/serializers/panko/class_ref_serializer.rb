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
  end
end
