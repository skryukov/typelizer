module Alba
  class NestedAttributeSerializer < BaseSerializer
    typelize_from ::User
    attributes :username, :name

    # Test nested attributes
    nested :details do
      attributes :role

      # Test deeply nested
      nested :timestamps do
        attributes :created_at, :updated_at
      end
    end

    # inference within trait
    trait :with_user_role do
      nested :user_role do
        attributes :role
      end
    end

    # TODO: introduce this test once Alba supports resource class methods in
    # nested blocks (okuramasafumi/alba#495)

    # # trait with nested attributes and typelize DSL
    # trait :with_integer_timestamps do
    #   nested :integer_timestamps do
    #     # typelize dsl within nested block
    #     typelize :integer
    #     attributes :created_at, :updated_at
    #   end
    # end
  end
end
