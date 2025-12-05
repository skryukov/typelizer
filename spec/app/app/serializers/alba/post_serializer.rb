module Alba
  class PostSerializer
    include Alba::Resource
    include Typelizer::DSL

    typelizer_config do |c|
      c.null_strategy = :nullable_and_optional
      c.serializer_model_mapper = lambda { |serializer|
        Object.const_get(serializer.name.gsub("Serializer", "").gsub("Alba::", ""))
      }
    end

    attributes :id, :title, :category, :body, :published_at

    has_one :user, serializer: UserSerializer

    one :created_by, serializer: UserSerializer do
      object.user
    end

    attributes :next_post
    typelize next_post: "Post"

    attribute :name, &:title
    typelize name: [:string, comment: "This is name", deprecated: true]

    # Trait for additional post details
    trait :details do
      typelize :string
      attribute :excerpt do
        body&.truncate(100)
      end

      typelize word_count: :number
      attributes :word_count
    end

    # Trait with author info
    trait :with_author do
      has_one :user, serializer: UserSerializer
      has_one :created_by, serializer: UserSerializer
    end
  end
end
