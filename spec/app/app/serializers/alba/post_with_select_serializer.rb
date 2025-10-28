module Alba
  class PostWithSelectSerializer
    include Alba::Resource
    include Typelizer::DSL

    typelizer_config do |c|
      c.null_strategy = :nullable_and_optional
      c.serializer_model_mapper = lambda { |serializer|
        Object.const_get(serializer.name.gsub("Serializer", "").gsub("Alba::", ""))
      }
    end

    attributes :id, :title, :content

    one :user, resource: UserSerializer, params: {select: [:id, :username]}
    one :author, resource: UserSerializer, params: {select: [:username, :active, :first_name]}
    has_one :latest_post, resource: PostSerializer
    has_many :related_posts, resource: PostSerializer, params: {select: [:id, :title]}
  end
end
