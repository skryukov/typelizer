# frozen_string_literal: true

# Serializer plugins are duck-typed: the established surface is
# properties/root_key/meta_fields, with optional hooks discovered via
# `respond_to?` (the `trait_interfaces` precedent). Newer optional hooks
# (`root_is_array`, `after_type_inference`) must be feature-detected the same
# way instead of assuming `SerializerPlugins::Base` ancestry, so third-party
# plugins that predate them keep working.
RSpec.describe "Duck-typed serializer plugins" do
  let(:duck_plugin_class) do
    Class.new do
      def initialize(serializer:, config:, context:)
      end

      def properties
        [Typelizer::Property.new(name: "id", type: "number", column_name: "id")]
      end

      def root_key
        nil
      end

      def meta_fields
        nil
      end
    end
  end

  it "flows through Interface#properties and friends without NoMethodError" do
    context = Typelizer::WriterContext.new(writer_name: nil)
    interface = Typelizer::Interface.new(serializer: Alba::PostSerializer, context: context)
    plugin = duck_plugin_class.new(serializer: Alba::PostSerializer, config: interface.config, context: context)
    allow(interface).to receive(:serializer_plugin).and_return(plugin)

    expect(interface.properties.map { |p| p.name.to_s }).to include("id")
    expect(interface.root_is_array).to be(false)
    expect(interface.wrapped?).to be_falsey
    expect { interface.fingerprint }.not_to raise_error
  end

  it "honors root_is_array/root_array_element when a duck plugin DOES implement them" do
    array_plugin_class = Class.new(duck_plugin_class) do
      def root_is_array
        true
      end

      def root_array_element
        nil
      end
    end

    context = Typelizer::WriterContext.new(writer_name: nil)
    interface = Typelizer::Interface.new(serializer: Alba::PostSerializer, context: context)
    plugin = array_plugin_class.new(serializer: Alba::PostSerializer, config: interface.config, context: context)
    allow(interface).to receive(:serializer_plugin).and_return(plugin)

    expect(interface.root_is_array).to be(true)
    expect(interface.wrapped?).to be_truthy
    output = Typelizer::Renderer.call("interface.ts.erb", interface: interface)
    expect(output).to include("Array<")
    expect(output).to include("id: number")
  end
end
