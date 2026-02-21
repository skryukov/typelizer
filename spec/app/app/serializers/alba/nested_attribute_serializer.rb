module Alba
  class NestedAttributeSerializer < BaseSerializer
    typelize_from ::User
    attributes :id, :username, :name

    nested :details do
      attribute :role

      nested :timestamps do
        attribute :created_at
        attribute :updated_at
      end
    end
  end
end
