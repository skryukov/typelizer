module Alba
  class OptionalKeySerializer < BaseSerializer
    typelize_from ::User
    attributes :id

    transform_keys :lower_camel

    typelize :string
    attribute :first_name, &:first_name

    typelize :string
    attribute :last_name, if: -> { true }, &:last_name
  end
end
