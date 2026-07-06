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

  it "does not leak the type-name override to subclasses" do
    parent = Class.new do
      include Alba::Resource
      include Typelizer::DSL

      typelize_as "BaseAlias"
      attributes :id
    end
    stub_const("Alba::BaseSerializer", parent)

    child = Class.new(parent)
    stub_const("Alba::ChildSerializer", child)

    context = Typelizer::WriterContext.new(writer_name: nil)

    # An inherited override would rename every descendant to "BaseAlias" and
    # collide them onto one file; the subclass must take its own mapper name.
    expect(context.interface_for(parent).name).to eq("BaseAlias")
    expect(context.interface_for(child).name).not_to eq("BaseAlias")
    expect(context.interface_for(child).name).to eq("AlbaChild")
  end

  it "is a no-op when typelizer is disabled" do
    # Mirror `DSL.disable!` on an anonymous module instead of calling it:
    # `disable!` prepends onto the real ClassMethods process-wide and cannot
    # be undone, which would poison every later example in a random-order run
    # (see dsl_disabled_spec.rb for the same isolation pattern).
    class_methods = Module.new do
      include Typelizer::DSL::ClassMethods
      prepend Typelizer::DSL::Disabled
    end
    klass = Class.new { extend class_methods }

    expect { klass.typelize_as "Whatever" }.not_to raise_error
    expect(klass.respond_to?(:_typelizer_type_name)).to be false
  end
end
