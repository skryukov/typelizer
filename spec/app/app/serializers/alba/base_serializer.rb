module Alba
  class BaseSerializer
    include Alba::Resource
    helper Typelizer::DSL

    typelizer_config.null_strategy = :nullable_and_optional
  end
end
