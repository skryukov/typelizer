module OjSerializers
  module Ar
    class PostSerializer < BaseSerializer
      typelize_from ::Post

      attributes :id, :title

      has_one :user, serializer: UserSerializer

      typelizer_config.associations_strategy = :active_record
    end
  end
end
