module Ams
  module Inherited
    class CustomTypeUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      typelize id: [:number, optional: true]
    end
  end
end
