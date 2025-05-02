module Ams
  module Inherited
    class ExtendedUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      typelize :string
      attribute :full_name do |object|
        object.username
      end
    end
  end
end
