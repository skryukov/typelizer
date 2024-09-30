module Alba
  class PoroSerializer
    include Alba::Serializer
    include Typelizer::DSL

    typelize_from Poro

    attributes :foo, bar: :String
  end
end
