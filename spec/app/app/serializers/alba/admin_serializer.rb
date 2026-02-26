module Alba
  class AdminSerializer < AbstractBaseSerializer
    typelize_from ::Admin

    attributes :id, :username, :name, :role, :active, :custom_attr
  end
end
