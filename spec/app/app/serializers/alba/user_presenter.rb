module Alba
  # Name without a Serializer/Resource suffix
  class UserPresenter < BaseSerializer
    typelize_from ::User
    attributes :username
  end
end
