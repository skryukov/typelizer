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

    attributes :next_post
    typelize next_post: "Post"
  end
end
