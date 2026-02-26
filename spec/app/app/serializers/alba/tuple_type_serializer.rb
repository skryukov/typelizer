# frozen_string_literal: true

module Alba
  class TupleTypeSerializer < BaseSerializer
    typelize_from ::User

    attributes :username

    typelize "[number, string]"
    attribute :coordinates do |user|
      [1, "hello"]
    end
  end
end
