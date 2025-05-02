module Alba
  module Inherited
    class RootUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      root_key!
    end
  end
end
