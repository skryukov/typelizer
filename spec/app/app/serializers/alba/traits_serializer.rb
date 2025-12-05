module Alba
  class TraitsSerializer < BaseSerializer
    typelize_from ::User
    attributes :id

    # Association with traits - should generate intersection type
    has_one :invitor, resource: TraitsSerializer, with_traits: [:basic, :complex]

    # has_many with traits - should generate Array<Type & Trait1 & Trait2>
    has_many :posts, resource: PostSerializer, with_traits: [:details]

    # Single trait (non-array) - should also work
    has_one :latest_post, resource: PostSerializer, with_traits: :details

    trait :basic do
      attributes :attr_string, :attr_integer,
        :attr_float, :attr_boolean
    end

    trait :time_related do
      attributes :attr_datetime, :attr_date, :attr_time
    end

    trait :complex do
      attributes :attr_json, :attr_array, :attr_range
    end

    trait :custom_attributes do
      typelize :string
      attribute :url do
        "https://example.com"
      end
    end

    # Trait with typelize options (nullable, comment, etc.)
    trait :with_options do
      typelize :string, nullable: true, comment: "Optional field"
      attribute :optional_field do
        nil
      end

      typelize nullable_name: [:string, nullable: true]
      attributes :nullable_name
    end

    # Trait with mixed attributes and associations
    trait :mixed do
      attributes :username, :name
      has_one :invitor, resource: TraitsSerializer
      has_many :posts, resource: PostSerializer, with_traits: [:details]
    end

    # Empty trait - edge case
    trait :empty do
    end
  end
end
