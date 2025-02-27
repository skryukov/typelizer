module OjSerializers
  class TransformKeysSerializer < UserSerializer
    attribute :created_at

    transform_keys :camel_case
  end
end
