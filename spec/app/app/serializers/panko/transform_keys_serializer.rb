module Panko
  class TransformKeysSerializer < UserSerializer
    attributes :created_at, key_transform: :camel_lower
  end
end
