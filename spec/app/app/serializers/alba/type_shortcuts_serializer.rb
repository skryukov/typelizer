# frozen_string_literal: true

module Alba
  class TypeShortcutsSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    # Optional shortcut: string?
    typelize "string?"
    attribute :nickname do |user|
      user.username
    end

    # Multi shortcut: string[]
    typelize "string[]"
    attribute :tags do |user|
      %w[admin user]
    end

    # Combined shortcuts: string?[]
    typelize "string?[]"
    attribute :roles do |user|
      %w[reader writer]
    end

    # Shortcut with explicit options (optional and nullable)
    typelize "string?", nullable: true
    attribute :status do |user|
      "active"
    end

    # Keyless typelize with number shortcut
    typelize "number?"
    attribute :score do |user|
      user.id * 10
    end

    # Hash-style typelize with shortcuts
    typelize bio: "string?", level: "number[]"

    attribute :bio do |user|
      "User bio"
    end

    attribute :level do |user|
      [1, 2, 3]
    end

    # Trait with shortcuts
    trait :with_metadata do
      typelize "string[]"
      attribute :metadata_tags do |user|
        %w[tag1 tag2]
      end

      typelize "number?[]"
      attribute :counts do |user|
        [1, 2, 3]
      end
    end
  end
end
