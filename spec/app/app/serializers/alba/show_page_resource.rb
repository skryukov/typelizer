# frozen_string_literal: true

# Regression fixture for https://github.com/skryukov/typelizer/issues/113:
# `many` on a resource without `typelize_from` must emit `Array<...>`.
module Alba
  class ShowPageResource
    include ::Alba::Resource

    helper Typelizer::DSL

    one :activity, resource: UserSerializer
    many :comments, resource: CommentSerializer

    typelize "AlbaPost[]"
    many :featured_posts, resource: PostSerializer, with_traits: [:details]
  end
end
