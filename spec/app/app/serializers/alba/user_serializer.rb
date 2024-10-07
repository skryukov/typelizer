module Alba
  class UserSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active

    has_one :invitor, resource: UserSerializer

    has_many :posts, resource: PostSerializer
    has_one :latest_post, resource: PostSerializer # Duplicated association

    class FooSerializer < UserSerializer
      typelize_from ::User
      attributes :created_at
    end
  end
end
