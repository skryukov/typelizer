module Alba
  # Keys typed by the serializer keep that type over a same-named User column
  # (string `name` and `username`, enum `role`)
  class ColumnCollisionSerializer < BaseSerializer
    typelize_from ::User

    one :name, resource: User::AuthorSerializer

    nested :username do
      attributes :active, :created_at
    end

    typelize role: User::AuthorSerializer
    attributes :role
  end
end
