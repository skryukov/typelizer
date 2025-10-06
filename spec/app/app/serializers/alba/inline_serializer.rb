module Alba
  class InlineSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :active, :post_ids

    has_many :untyped_posts do
      attributes :id, :title
    end

    has_many :posts do
      typelize id: :number

      attributes :id, title: [String, true]
    end

    has_many :deep_posts do
      typelize_from ::Post
      attributes :id, :title

      has_one :user do
        typelize_from ::User
        attributes :id, :username
      end
    end
  end
end
