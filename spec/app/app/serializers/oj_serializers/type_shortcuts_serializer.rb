# frozen_string_literal: true

module OjSerializers
  class TypeShortcutsSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    # Optional shortcut: string?
    typelize "string?"
    attribute :nickname do |object|
      object.username
    end

    # Multi shortcut: string[]
    typelize "string[]"
    attribute :tags do
      %w[admin user]
    end

    # Combined shortcuts: string?[]
    typelize "string?[]"
    attribute :roles do
      %w[reader writer]
    end

    # Shortcut with explicit options (optional and nullable)
    typelize "string?", nullable: true
    attribute :status do
      "active"
    end

    # Keyless typelize with number shortcut
    typelize "number?"
    attribute :score do |object|
      object.id * 10
    end

    # Hash-style typelize with shortcuts
    typelize bio: "string?", level: "number[]"

    attribute :bio do
      "User bio"
    end

    attribute :level do
      [1, 2, 3]
    end
  end
end
