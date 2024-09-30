module Alba
  class PoroSerializer
    include Alba::Serializer
    include Typelizer::DSL

    typelize_from :poro

    typelizer_config do |c|
      # This is required
      c.model_plugin = Typelizer::ModelPlugins::Poro
    end

    attributes :foo, bar: :String
  end
end
