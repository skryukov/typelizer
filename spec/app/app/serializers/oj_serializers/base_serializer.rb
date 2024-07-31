module OjSerializers
  class BaseSerializer < Oj::Serializer
    include Typelizer::DSL

    typelizer_config.null_strategy = :nullable_and_optional
  end
end
