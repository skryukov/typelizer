# frozen_string_literal: true

RSpec.describe Typelizer do
  describe ".interfaces" do
    it "returns an array of Interface objects" do
      interfaces = Typelizer.interfaces
      expect(interfaces).to be_an(Array)
      expect(interfaces).not_to be_empty
      expect(interfaces).to all(be_a(Typelizer::Interface))
    end

    it "does not include empty interfaces" do
      interfaces = Typelizer.interfaces
      interfaces.each do |iface|
        expect(iface).not_to be_empty
      end
    end

    it "accepts a writer_name parameter" do
      interfaces = Typelizer.interfaces(writer_name: :default)
      expect(interfaces).to be_an(Array)
      expect(interfaces).not_to be_empty
    end

    it "returns empty array when no serializers are registered" do
      original = Typelizer.base_classes.dup
      Typelizer.send(:base_classes=, Set.new)

      expect(Typelizer.interfaces).to eq([])
    ensure
      Typelizer.send(:base_classes=, original)
    end
  end

  describe ".openapi_schemas" do
    it "returns a hash of interface_name => openapi_schema" do
      schemas = Typelizer.openapi_schemas
      expect(schemas).to be_a(Hash)
      expect(schemas).not_to be_empty

      schemas.each do |name, schema|
        expect(name).to be_a(String)
        expect(schema).to be_a(Hash)
        expect(schema[:type]).to eq(:object)
        expect(schema[:properties]).to be_a(Hash)
      end
    end
  end
end

RSpec.describe Typelizer::OpenAPI do
  describe ".schema_for" do
    let(:context) { Typelizer::WriterContext.new }

    it "returns a valid OpenAPI schema for a serializer with AR columns" do
      serializer = Alba::Ar::PostSerializer
      interface = context.interface_for(serializer)
      schema = described_class.schema_for(interface)

      expect(schema[:type]).to eq(:object)
      expect(schema[:properties]).to be_a(Hash)

      # Post has integer :id column, should map to integer not number
      if schema[:properties].key?(:id)
        expect(schema[:properties][:id][:type]).to eq(:integer)
      end

      # Post has datetime :published_at
      if schema[:properties].key?(:published_at)
        expect(schema[:properties][:published_at]).to include(type: :string, format: :"date-time")
      end
    end

    it "includes required fields (non-optional properties)" do
      serializer = Alba::Ar::PostSerializer
      interface = context.interface_for(serializer)
      schema = described_class.schema_for(interface)

      if schema[:required]
        expect(schema[:required]).to be_an(Array)
        schema[:required].each do |req|
          expect(schema[:properties]).to have_key(req)
        end
      end
    end

    it "omits required key when all properties are optional" do
      prop = Typelizer::Property.new(name: :field, type: :string, optional: true)
      interface = instance_double(Typelizer::Interface, properties: [prop])

      schema = described_class.schema_for(interface)
      expect(schema).not_to have_key(:required)
    end
  end

  describe "resolving serializer class references" do
    let(:context) { Typelizer::WriterContext.new }

    # Tests that `typelize field: SomeSerializer` (class constant) and
    # `typelize field: "Module::SomeSerializer"` (class name string)
    # both resolve to Interface objects, producing correct $ref in OpenAPI
    # and correct type names in TypeScript.
    {
      "Alba" => {serializer: Alba::ClassRefSerializer, user_schema: "AlbaUser"},
      "AMS" => {serializer: Ams::ClassRefSerializer, user_schema: "AmsUser"},
      "OjSerializers" => {serializer: OjSerializers::ClassRefSerializer, user_schema: "OjSerializersUser"},
      "Panko" => {serializer: Panko::ClassRefSerializer, user_schema: "PankoUser"}
    }.each do |plugin, config|
      context "with #{plugin}" do
        let(:interface) { context.interface_for(config[:serializer]) }
        let(:schema) { described_class.schema_for(interface) }
        let(:user_schema_name) { config[:user_schema] }

        it "resolves class constant in typelize to Interface" do
          reviewer_prop = interface.properties.find { |p| p.name.to_s == "reviewer" }
          expect(reviewer_prop.type).to be_a(Typelizer::Interface)
        end

        it "resolves class name string in typelize to Interface" do
          editor_prop = interface.properties.find { |p| p.name.to_s == "editor" }
          expect(editor_prop.type).to be_a(Typelizer::Interface)
        end

        it "generates $ref for class constant reference (nullable)" do
          reviewer_schema = schema[:properties]["reviewer"]
          expect(reviewer_schema).to include(:allOf)
          expect(reviewer_schema[:allOf].first).to eq({"$ref" => "#/components/schemas/#{user_schema_name}"})
          expect(reviewer_schema[:nullable]).to eq(true)
        end

        it "generates $ref for class name string reference" do
          editor_schema = schema[:properties]["editor"]
          expect(editor_schema).to eq({"$ref" => "#/components/schemas/#{user_schema_name}"})
        end
      end
    end

    # Tests that `typelize previous_post: PostSerializer` resolves self-references
    {
      "Alba" => {serializer: Alba::PostSerializer, post_schema: "AlbaPost"},
      "AMS" => {serializer: Ams::PostSerializer, post_schema: "AmsPost"},
      "OjSerializers" => {serializer: OjSerializers::PostSerializer, post_schema: "OjSerializersPost"},
      "Panko" => {serializer: Panko::PostSerializer, post_schema: "PankoPost"}
    }.each do |plugin, config|
      context "#{plugin} self-referencing class constant" do
        it "generates $ref for previous_post" do
          interface = context.interface_for(config[:serializer])
          schema = described_class.schema_for(interface)

          previous_post_schema = schema[:properties]["previous_post"]
          expect(previous_post_schema).to eq({"$ref" => "#/components/schemas/#{config[:post_schema]}"})
        end
      end
    end
  end
end
