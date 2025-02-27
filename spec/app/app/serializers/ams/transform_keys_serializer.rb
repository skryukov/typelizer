module Ams
  class TransformKeysSerializer < UserSerializer
    attribute :created_at, key_transform: :camel_lower
  end
end
