module Ams
  class UserSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active

    has_one :invitor, serializer: UserSerializer

    has_many :posts, serializer: PostSerializer

    typelize id: [:string, nullable: true]

    class FooSerializer < UserSerializer
      typelize_from ::User
      attributes :created_at

      typelize id: [:number, optional: true]
    end
  end
end
