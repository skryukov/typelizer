# frozen_string_literal: true

RSpec.describe "Typelizer::DSL#typelize_as", type: :typelizer do
  it "overrides the generated TypeScript type name on a class-based serializer" do
    klass = Class.new do
      include Alba::Resource
      include Typelizer::DSL

      typelize_as "MyAlias"
      attributes :id
    end
    stub_const("Alba::CustomNamedSerializer", klass)

    context = Typelizer::WriterContext.new(writer_name: nil)
    interface = context.interface_for(klass)

    expect(interface.name).to eq("MyAlias")
  end

  it "wins over the configured serializer_name_mapper" do
    klass = Class.new do
      include Alba::Resource
      include Typelizer::DSL

      typelize_as "ExplicitName"
      attributes :id
    end
    stub_const("Alba::SomeOtherSerializer", klass)

    context = Typelizer::WriterContext.new(writer_name: nil)
    interface = context.interface_for(klass)

    expect(interface.name).to eq("ExplicitName")
  end

  it "is a no-op when typelizer is disabled" do
    Typelizer::DSL.disable!
    klass = Class.new { include Typelizer::DSL }
    expect { klass.typelize_as "Whatever" }.not_to raise_error
    expect(klass.respond_to?(:_typelizer_type_name)).to be false
  ensure
    Typelizer::DSL::ClassMethods.send(:remove_method, :typelize_as) if Typelizer::DSL::Disabled.method_defined?(:typelize_as)
  end
end
