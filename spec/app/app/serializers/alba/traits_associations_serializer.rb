module Alba
  class TraitsAssociationsSerializer < BaseSerializer
    typelize_from ::User

    # has_one with multiple traits
    has_one :user, serializer: TraitsSerializer, with_traits: [:basic, :complex]

    # has_many with traits - Array type with intersection
    has_many :posts, resource: PostSerializer, with_traits: [:details, :with_author]

    # Single trait reference (non-array syntax)
    has_one :latest_post, resource: PostSerializer, with_traits: :details

    trait :associations do
      has_one :user, serializer: TraitsSerializer, with_traits: [:custom_attributes]
    end

    # Trait with has_many association with traits
    trait :with_posts do
      has_many :posts, resource: PostSerializer, with_traits: [:details]
    end

    # Trait combining different association types
    trait :full do
      has_one :invitor, resource: TraitsSerializer, with_traits: [:basic]
      has_many :posts, resource: PostSerializer, with_traits: [:details, :with_author]
      attributes :username
    end

    trait :with_aliased_associations do
      has_one :user, serializer: TraitsSerializer, key: :user_alias

      has_many :posts, resource: PostSerializer, key: :custom_posts, with_traits: [:details]
    end
  end
end
