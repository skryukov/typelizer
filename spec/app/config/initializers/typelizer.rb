Typelizer.configure do |c|
  c.dirs = [
    Rails.root.join("app", "serializers")
  ]

  c.types_global = %w[Array Date Record]

  c.comments = true
end

# Scoped camel_case writer — exercises `properties_transformer` across
# representative serializers for snapshot coverage.
module CamelCaseWriterFixture
  SERIALIZERS = %w[
    Alba::NestedAttributeSerializer
    Alba::MetaSerializer
    Alba::PostSerializer
    Alba::TraitsSerializer
    Alba::Inherited::ExtendedUserSerializer
    Alba::TransformKeysSerializer
  ].freeze

  TRANSFORMER = lambda do |properties|
    properties.map { |prop| prop.with(name: prop.name.to_s.camelize(:lower)) }
  end

  def self.output_dir
    Rails.root.join("app/javascript/types/camel_case")
  end

  def self.register!(configuration)
    configuration.writer(:camel_case) do |w|
      w.output_dir = output_dir
      w.properties_transformer = TRANSFORMER
      w.reject_class = ->(serializer:) { !SERIALIZERS.include?(serializer.name) }
    end
  end
end

CamelCaseWriterFixture.register!(Typelizer.configuration)
