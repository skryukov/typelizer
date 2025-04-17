module Panko
  class UserSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active, :name, :first_name

    has_one :invitor, serializer: UserSerializer

    has_many :posts, serializer: PostSerializer
    has_one :post, resource: PostSerializer, name: :latest_post

    typelize id: [:string, nullable: true]

    typelize :string
    def first_name
      object.username.split(" ").first
    end

    class FooSerializer < UserSerializer
      typelize_from ::User
      attributes :created_at

      typelize id: [:number, optional: true]
    end
  end
end
