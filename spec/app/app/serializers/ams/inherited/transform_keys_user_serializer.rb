module Ams
  module Inherited
    class TransformKeysUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      attribute :created_at, key_transform: :camel_lower
    end
  end
end
