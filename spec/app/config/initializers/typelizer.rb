Typelizer.configure do |c|
  c.dirs = [
    Rails.root.join("app", "serializers")
  ]

  c.types_global = %w[Array Date Record]

  c.comments = true
end

# Auto-discover Jbuilder templates for type generation.
Rails.application.config.after_initialize do
  Typelizer::Jbuilder.discover(Rails.root.join("app/views").to_s)
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

# Scoped enum_runtime writer — exercises `enum_runtime = true` output for
# Enums.ts and index.ts across serializers that hit named enums.
module EnumRuntimeWriterFixture
  SERIALIZERS = %w[
    Alba::PostSerializer
    Alba::UserSerializer
    Typelizer::Jbuilder::Templates::PostsPost
  ].freeze

  def self.output_dir
    Rails.root.join("app/javascript/types/enum_runtime")
  end

  def self.register!(configuration)
    configuration.writer(:enum_runtime) do |w|
      w.output_dir = output_dir
      w.enum_runtime = true
      w.reject_class = ->(serializer:) { !SERIALIZERS.include?(serializer.name) }
    end
  end
end

EnumRuntimeWriterFixture.register!(Typelizer.configuration)

# Scoped enum_runtime + verbatim_module_syntax writer — exercises the interaction
# between value re-exports for enums and the verbatim form for interface re-exports.
module EnumRuntimeVerbatimWriterFixture
  SERIALIZERS = %w[
    Alba::PostSerializer
    Alba::UserSerializer
  ].freeze

  def self.output_dir
    Rails.root.join("app/javascript/types/enum_runtime_verbatim")
  end

  def self.register!(configuration)
    configuration.writer(:enum_runtime_verbatim) do |w|
      w.output_dir = output_dir
      w.enum_runtime = true
      w.verbatim_module_syntax = true
      w.reject_class = ->(serializer:) { !SERIALIZERS.include?(serializer.name) }
    end
  end
end

EnumRuntimeVerbatimWriterFixture.register!(Typelizer.configuration)
