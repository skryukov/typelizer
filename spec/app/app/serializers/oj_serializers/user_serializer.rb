module OjSerializers
  class UserSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active

    has_one :invitor, serializer: UserSerializer

    has_many :posts, serializer: PostSerializer

    class FooSerializer < UserSerializer
      typelize_from ::User
      attributes :created_at
    end
  end
end
