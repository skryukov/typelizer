# frozen_string_literal: true

module Alba
  class InlineShapeSerializer < BaseSerializer
    typelize_from ::User

    attributes :username

    # Keyless positional-hash form: the next attribute is typed as the inline shape.
    typelize({id: :number, label?: :string})
    attribute :category do |user|
      {id: 1, label: "main"}
    end

    # Shape + options: array of shapes, nullable.
    typelize({version: :number, tag?: :string}, multi: true, nullable: true)
    attribute :revisions do |user|
      []
    end

    # Nested shape + '?:' suffix on keys.
    typelize({
      customer: {name: :string, email?: :string},
      totals: {subtotal: :number, grand_total: :number}
    })
    attribute :summary do |user|
      {customer: {name: user.name}, totals: {subtotal: 0, grand_total: 0}}
    end

    # Hash-form typelize with '?:' suffix on the attribute key.
    typelize nickname?: :string
    attribute :nickname do |user|
      user.username
    end
  end
end
