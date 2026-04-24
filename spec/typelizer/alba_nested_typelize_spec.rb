# frozen_string_literal: true

RSpec.describe "Alba nested typelize key lookup" do
  let(:context) { Typelizer::WriterContext.new }

  def nested_prop(serializer, name)
    context.interface_for(serializer).properties.find { |p| p.name.to_s == name.to_s }
  end

  def build_resource(&block)
    klass = Class.new do
      include ::Alba::Resource

      helper Typelizer::DSL
    end
    klass.class_eval(&block)
    klass
  end

  it "applies typelize override keyed by the pre-transform attribute name" do
    resource = build_resource do
      transform_keys :lower_camel
      nested :profile do
        attribute :custom_field
        typelize custom_field: :string
      end
    end
    stub_const("AlbaNestedTypelizeByColumnName", resource)

    profile = nested_prop(resource, :profile)
    sub = profile.type.properties.first
    expect(sub.name).to eq("customField")
    expect(sub.type).to eq(:string)
  end

  it "falls back to the post-transform name when typelize uses the camelCase key" do
    resource = build_resource do
      transform_keys :lower_camel
      nested :profile do
        attribute :custom_field
        typelize customField: :string
      end
    end
    stub_const("AlbaNestedTypelizeByName", resource)

    profile = nested_prop(resource, :profile)
    sub = profile.type.properties.first
    expect(sub.name).to eq("customField")
    expect(sub.type).to eq(:string)
  end
end
