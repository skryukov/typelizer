# frozen_string_literal: true

module Panko
  class TypeShortcutsSerializer < BaseSerializer
    typelize_from ::User

    attributes :id
    attributes :nickname, :tags, :roles, :status, :score, :bio, :level

    # Optional shortcut: string?
    typelize "string?"
    def nickname
      object.username
    end

    # Multi shortcut: string[]
    typelize "string[]"
    def tags
      %w[admin user]
    end

    # Combined shortcuts: string?[]
    typelize "string?[]"
    def roles
      %w[reader writer]
    end

    # Shortcut with explicit options (optional and nullable)
    typelize "string?", nullable: true
    def status
      "active"
    end

    # Keyless typelize with number shortcut
    typelize "number?"
    def score
      object.id * 10
    end

    # Hash-style typelize with shortcuts
    typelize bio: "string?", level: "number[]"

    def bio
      "User bio"
    end

    def level
      [1, 2, 3]
    end
  end
end
