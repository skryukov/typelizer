# frozen_string_literal: true

module Panko
  # Aliased attributes are named by the alias and typed by the source column
  class AliasesSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    aliases username: :login, created_at: :joined_at
  end
end
