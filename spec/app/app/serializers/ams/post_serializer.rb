module Ams
  class PostSerializer < ActiveModel::Serializer
    include Typelizer::DSL

    typelize_from ::Post
    typelizer_config.null_strategy = :nullable_and_optional

    attributes :id, :title, :category, :body, :published_at

    has_one :user, serializer: UserSerializer

    belongs_to :created_by, serializer: UserSerializer do
      object.user
    end

    typelize :string
    attribute :name, deprecated: "Use 'title' instead."
    def name
      title
    end
  end
end
