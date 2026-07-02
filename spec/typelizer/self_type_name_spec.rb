# frozen_string_literal: true

# Interface#self_type_name derives the name a serializer uses to reference
# ITSELF in typelize declarations (so it can be excluded from imports). It
# must strip only a TRAILING Serializer/Resource suffix from the demodulized
# class name: a leftmost scan would extract "A" from
# `AResourceFoo::UserSerializer` ("A" followed by "Resource…"). Names with
# no suffix at all (jbuilder's `Templates::Post` constants) must not crash.
RSpec.describe Typelizer::Interface, "#self_type_name" do
  let(:context) { Typelizer::WriterContext.new(writer_name: nil) }

  def self_type_name_for(class_name)
    stub_const(class_name, Class.new)
    interface = described_class.new(serializer: Object.const_get(class_name), context: context)
    interface.send(:self_type_name)
  end

  it "strips the Serializer suffix from a namespaced serializer" do
    expect(self_type_name_for("Foo::UserSerializer")).to eq("User")
  end

  it "strips the Resource suffix" do
    expect(self_type_name_for("UserResource")).to eq("User")
  end

  it "is not confused by Serializer/Resource appearing mid-namespace" do
    expect(self_type_name_for("AResourceFoo::UserSerializer")).to eq("User")
  end

  it "keeps the demodulized name when there is no suffix to strip" do
    expect(self_type_name_for("Templates::Post")).to eq("Post")
  end
end
