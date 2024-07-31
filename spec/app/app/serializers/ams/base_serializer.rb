module Ams
  class BaseSerializer < ActiveModel::Serializer
    include Typelizer::DSL

    typelizer_config.null_strategy = :nullable_and_optional
  end
end
