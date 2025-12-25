module Alba
  module Ar
    class UserSerializer < BaseSerializer
      typelize_from ::User
      attributes :id, :username, :skills, :settings, :metadata

      has_one :invitor, serializer: UserSerializer

      has_many :posts, serializer: PostSerializer
      has_one :latest_post, serializer: PostSerializer

      typelizer_config.associations_strategy = :active_record
    end
  end
end
