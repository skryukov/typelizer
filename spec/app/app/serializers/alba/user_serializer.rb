module Alba
  class UserSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active, :name, :sir_name, :role

    has_one :invitor, resource: UserSerializer

    has_many :posts, resource: PostSerializer
    has_one :latest_post, resource: PostSerializer # Duplicated association
    has_many :posts, resource: PostSerializer, key: :custom_key_posts

    typelize id: [:string, nullable: true]

    typelize :string, comment: "This is sir name from the name"
    def sir_name(object)
      object.username.split(" ").last
    end

    typelize :string
    attribute :first_name do |object|
      object.username.split(" ").first
    end

    class FooSerializer < UserSerializer
      typelize_from ::User
      attributes :created_at

      typelize id: [:number, optional: true]
    end
  end
end
