module Alba
  class TransformKeysSerializer < UserSerializer
    attributes :created_at

    transform_keys :lower_camel
  end
end
