module OjSerializers
  module User
    class AuthorSerializer < BaseSerializer
      typelize_from ::User

      typelize username: [:string, nullable: true]
      attributes :id, :username

      has_many :posts, serializer: PostSerializer, if: ->(u) { u.posts.any? }

      attribute :avatar do
        "https://example.com/avatar.png" if active?
      end

      # typelize typed_avatar: [:string, nullable: true]
      # typelize ["string", "null"]
      # typelize "string | null"
      typelize :string, nullable: true
      attribute :typed_avatar do
        "https://example.com/avatar.png" if active?
      end
    end
  end
end
