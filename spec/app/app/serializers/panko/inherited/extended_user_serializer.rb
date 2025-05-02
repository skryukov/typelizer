module Panko
  module Inherited
    class ExtendedUserSerializer < UserSerializer
      typelizer_config.inheritance_strategy = :inheritance

      attributes :full_name

      typelize :string
      def full_name
        object.username
      end
    end
  end
end
