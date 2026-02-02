module Panko
  module Ar
    class DelegateSerializer < BaseSerializer
      typelize_from ::Post

      attributes :id, :name, :user_username, :author_active, :user_role
    end
  end
end
