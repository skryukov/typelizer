module Alba
  class DashKeysSerializer < BaseSerializer
    typelize_from ::User
    attributes :username, :created_at

    transform_keys :dash
  end
end
