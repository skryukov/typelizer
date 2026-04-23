# frozen_string_literal: true

RSpec.describe Typelizer::Shape do
  def prop(name, type, **attrs)
    Typelizer::Property.new(name: name, type: type, optional: false, nullable: false, multi: false, **attrs)
  end

  describe "#render" do
    it "emits a TS object type literal" do
      shape = described_class.new(properties: [prop(:id, :number), prop(:name, :string)])
      expect(shape.render).to eq("{\n  id: number;\n  name: string;\n}")
    end

    it "renders optional fields with '?:'" do
      shape = described_class.new(properties: [prop(:id, :number), prop(:name, :string, optional: true)])
      expect(shape.render).to include("name?: string;")
    end

    it "renders nested shapes recursively" do
      inner = described_class.new(properties: [prop(:city, :string)])
      outer = described_class.new(properties: [prop(:address, inner)])
      expect(outer.render).to eq("{\n  address: {\n    city: string;\n  };\n}")
    end
  end

  describe "value semantics" do
    it "compares equal by structure" do
      a = described_class.new(properties: [prop(:id, :number)])
      b = described_class.new(properties: [prop(:id, :number)])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is frozen" do
      shape = described_class.new(properties: [])
      expect(shape).to be_frozen
      expect(shape.properties).to be_frozen
    end
  end

  describe "Property rendering with Shape type" do
    it "renders a shape-typed property" do
      shape = described_class.new(properties: [prop(:id, :number), prop(:label, :string, optional: true)])
      p = prop(:category, shape)
      expect(p.render).to eq("category: {\n  id: number;\n  label?: string;\n}")
    end

    it "composes with multi: true" do
      shape = described_class.new(properties: [prop(:id, :number)])
      p = prop(:items, shape, multi: true)
      expect(p.render).to eq("items: Array<{\n  id: number;\n}>")
    end

    it "composes with nullable: true" do
      shape = described_class.new(properties: [prop(:id, :number)])
      p = prop(:address, shape, nullable: true)
      expect(p.render).to eq("address: {\n  id: number;\n} | null")
    end

    it "composes with optional at the property level" do
      shape = described_class.new(properties: [prop(:id, :number)])
      p = prop(:meta, shape, optional: true)
      expect(p.render).to eq("meta?: {\n  id: number;\n}")
    end
  end

  describe "OpenAPI emission for shape-typed property" do
    it "emits an object schema with properties and required" do
      shape = described_class.new(properties: [
        prop(:id, :number),
        prop(:label, :string, optional: true)
      ])
      p = prop(:category, shape)
      schema = Typelizer::OpenAPI.property_schema(p)
      expect(schema).to eq(
        type: :object,
        properties: {
          id: {type: :number},
          label: {type: :string}
        },
        required: [:id]
      )
    end

    it "wraps shape in array when multi: true" do
      shape = described_class.new(properties: [prop(:id, :number)])
      p = prop(:items, shape, multi: true)
      schema = Typelizer::OpenAPI.property_schema(p)
      expect(schema[:type]).to eq(:array)
      expect(schema[:items][:type]).to eq(:object)
      expect(schema[:items][:properties]).to eq(id: {type: :number})
    end
  end
end
