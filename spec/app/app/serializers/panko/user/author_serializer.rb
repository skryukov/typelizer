module Panko
  module User
    class AuthorSerializer < BaseSerializer
      typelize_from ::User

      typelize username: [:string, nullable: true, comment: "Author login handle"]
      attributes :id, :username, :avatar, :typed_avatar

      has_many :posts, serializer: PostSerializer, if: ->(u) { u.posts.any? }

      def avatar
        "https://example.com/avatar.png" if active?
      end

      # typelize typed_avatar: [:string, nullable: true]
      # typelize ["string", "null"]
      # typelize "string | null"
      typelize :string, nullable: true
      def typed_avatar
        "https://example.com/avatar.png" if active?
      end
    end
  end
end
