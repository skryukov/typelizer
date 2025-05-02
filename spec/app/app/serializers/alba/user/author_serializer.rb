module Alba
  module User
    class AuthorSerializer < BaseSerializer
      typelize_from ::User

      typelize username: [:string, nullable: true, comment: "Author login handle"]
      attributes :id, :username

      has_many :posts, resource: PostSerializer, if: ->(u) { u.posts.any? }

      typelize invitor: {nullable: false}
      has_one :invitor, resource: UserSerializer

      attribute :avatar do
        "https://example.com/avatar.png" if active?
      end

      # typelize typed_avatar: [:string, nullable: true]
      # typelize ["string", "null"]
      # typelize "string | null"
      typelize :string, nullable: true, comment: <<~TXT
        Typed avatar URL
        Active user only
      TXT
      attribute :typed_avatar do
        "https://example.com/avatar.png" if active?
      end
    end
  end
end
