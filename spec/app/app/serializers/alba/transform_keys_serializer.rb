module Alba
  class TransformKeysSerializer < UserSerializer
    attributes :created_at

    transform_keys :lower_camel

    trait :with_profile do
      one :latest_post, resource: PostSerializer
    end

    trait :with_details do
      many :custom_key_posts, resource: PostSerializer, key: :my_custom_posts
    end
  end
end
