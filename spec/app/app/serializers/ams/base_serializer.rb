module Ams
  class BaseSerializer < ActiveModel::Serializer
    include Typelizer::DSL

    typelizer_config.null_strategy = :nullable_and_optional

    typelize id: [:string, comment: "Unique identifier"]
    def id
      Base64.urlsafe_encode64(object.id.to_s)
    end
  end
end
