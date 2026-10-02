module Ams
  # Associations keep their serializer type over a same-named User column
  # (string `name`, enum `role`)
  class ColumnCollisionSerializer < BaseSerializer
    typelize_from ::User

    has_one :name, serializer: User::AuthorSerializer
    has_one :role, serializer: User::AuthorSerializer
  end
end
