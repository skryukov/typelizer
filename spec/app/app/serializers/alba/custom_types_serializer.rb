# frozen_string_literal: true

module Alba
  class CustomTypesSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    # String literal union
    typelize provider: "'cloudpayments' | 'tiptoppay'"

    attribute :provider do |user|
      "cloudpayments"
    end

    # Inline object type with nullable field — | inside {} must not split
    typelize metadata: "{ name: string; visitorId: string | null }"

    attribute :metadata do |user|
      {name: user.username, visitorId: nil}
    end

    # Generic type with | inside <> must not split
    typelize lookup: "Record<string, number | null>"

    attribute :lookup do |user|
      {}
    end

    # Tuple with | inside [] must not split
    typelize pair: "[string | null, number]"

    attribute :pair do |user|
      [nil, 1]
    end

    # Top-level union of complex types
    typelize result: "{ ok: boolean } | { error: string }"

    attribute :result do |user|
      {ok: true}
    end

    # Nullable complex type — top-level null extracted, nested | preserved
    typelize config: "{ retries: number | null } | null"

    attribute :config do |user|
      nil
    end

    # String literal union with nullable
    typelize status: "'active' | 'inactive' | null"

    attribute :status do |user|
      "active"
    end

    # Single string literal with nullable
    typelize kind: "'user' | null"

    attribute :kind do |user|
      "user"
    end
  end
end
