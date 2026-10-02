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

    # trait with nested attributes and typelize DSL
    trait :with_integer_timestamps do
      nested :integer_timestamps do
        typelize :number
        attribute(:created_at) { |user| user.created_at.to_i }

        typelize :number
        attribute(:updated_at) { |user| user.updated_at.to_i }
      end
    end
  end
end
