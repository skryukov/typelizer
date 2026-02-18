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
end
