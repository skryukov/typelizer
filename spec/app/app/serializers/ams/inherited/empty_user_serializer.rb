module Ams
  module Inherited
    class EmptyUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance
    end
  end
end
