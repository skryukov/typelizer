module OjSerializers
  module Inherited
    class TransformKeysUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      transform_keys :camel_case
    end
  end
end
