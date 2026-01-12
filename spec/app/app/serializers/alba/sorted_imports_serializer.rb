module Alba
  class SortedImportsSerializer < BaseSerializer
    typelizer_config do |c|
      c.imports_sort_order = :alphabetical
    end

    typelize_from ::User

    # has_one with multiple traits - generates imports for AlbaTraits, AlbaTraitsBasicTrait, AlbaTraitsComplexTrait
    has_one :user, serializer: TraitsSerializer, with_traits: [:basic, :complex]

    # has_many with traits - generates imports for AlbaPost, AlbaPostDetailsTrait, AlbaPostWithAuthorTrait
    has_many :posts, resource: PostSerializer, with_traits: [:details, :with_author]

    # Single trait reference
    has_one :latest_post, resource: PostSerializer, with_traits: :details
  end
end
