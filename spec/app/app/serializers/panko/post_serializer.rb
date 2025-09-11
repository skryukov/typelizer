module Panko
  class PostSerializer < Panko::Serializer
    include Typelizer::DSL

    typelize_from ::Post
    typelizer_config.null_strategy = :nullable_and_optional

    attributes :id, :title, :category, :body, :published_at

    has_one :user, serializer: UserSerializer

    has_one :created_by, serializer: UserSerializer

    def created_by
      object.user
    end
  end
end
