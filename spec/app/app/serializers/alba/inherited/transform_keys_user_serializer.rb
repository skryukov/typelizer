module Alba
  module Inherited
    class TransformKeysUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      transform_keys :lower_camel
    end
  end
end
