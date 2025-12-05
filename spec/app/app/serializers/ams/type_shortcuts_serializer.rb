# frozen_string_literal: true

module Ams
  class TypeShortcutsSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    # Optional shortcut: string?
    typelize "string?"
    attribute :nickname

    def nickname
      object.username
    end

    # Multi shortcut: string[]
    typelize "string[]"
    attribute :tags

    def tags
      %w[admin user]
    end

    # Combined shortcuts: string?[]
    typelize "string?[]"
    attribute :roles

    def roles
      %w[reader writer]
    end

    # Shortcut with explicit options (optional and nullable)
    typelize "string?", nullable: true
    attribute :status

    def status
      "active"
    end

    # Keyless typelize with number shortcut
    typelize "number?"
    attribute :score

    def score
      object.id * 10
    end

    # Hash-style typelize with shortcuts
    typelize bio: "string?", level: "number[]"

    attribute :bio
    attribute :level

    def bio
      "User bio"
    end

    def level
      [1, 2, 3]
    end
  end
end
