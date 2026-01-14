# frozen_string_literal: true

module Alba
  class UnionSortedSerializer < BaseSerializer
    typelizer_config do |c|
      c.properties_sort_order = :alphabetical
    end

    typelize_from ::User

    # Union type with multiple types - should be sorted alphabetically
    typelize sections: ["ZebraSection", "AlphaSection", "BetaSection"]
    attribute :sections do |user|
      []
    end

    # Union type in an array - should be sorted inside Array<>
    typelize items: ["TypeZ", "TypeA", "TypeM", multi: true]
    attribute :items do |user|
      []
    end

    # Enum values - should be sorted alphabetically
    typelize status: [:string, enum: %w[zebra apple banana]]
    attribute :status do |user|
      "active"
    end

    # Regular properties to test property sorting still works
    attributes :id, :username

    typelize email: :string
    attribute :email do |user|
      "test@example.com"
    end
  end
end
