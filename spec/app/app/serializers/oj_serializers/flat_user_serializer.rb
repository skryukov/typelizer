module OjSerializers
  class FlatUserSerializer < BaseSerializer
    flat_one :invitor, serializer: UserSerializer
  end
end
