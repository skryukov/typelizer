# frozen_string_literal: true

RSpec.describe Typelizer::TypeParser do
  describe "DSL integration" do
    let(:serializer_class) do
      Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize name: "string?"
        typelize age: "number[]"
        typelize tags: "string?[]"
        typelize score: [:number?, nullable: true]
        typelize bio: "string | null"
        typelize role: [:string, :null]
        typelize status: [:"string | null", optional: true]
        typelize priority: [:"number | null"]
      end
    end

    it "parses optional shortcut in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:name]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:optional]).to be true
    end

    it "parses multi shortcut in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:age]
      expect(attrs[:type]).to eq(:number)
      expect(attrs[:multi]).to be true
    end

    it "parses combined shortcuts in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:tags]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:optional]).to be true
      expect(attrs[:multi]).to be true
    end

    it "merges shortcuts with explicit options" do
      attrs = serializer_class._typelizer_attributes[:score]
      expect(attrs[:type]).to eq(:number)
      expect(attrs[:optional]).to be true
      expect(attrs[:nullable]).to be true
    end

    it "extracts nullable from single string union with null" do
      attrs = serializer_class._typelizer_attributes[:bio]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:nullable]).to be true
    end

    it "extracts nullable from multi-arg with null" do
      attrs = serializer_class._typelizer_attributes[:role]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:nullable]).to be true
    end

    it "extracts nullable from union and preserves explicit options" do
      attrs = serializer_class._typelizer_attributes[:status]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:nullable]).to be true
      expect(attrs[:optional]).to be true
    end

    it "extracts nullable from inline union type" do
      attrs = serializer_class._typelizer_attributes[:priority]
      expect(attrs[:type]).to eq(:number)
      expect(attrs[:nullable]).to be true
    end
  end

  describe "DSL integration with string literal arrays" do
    let(:serializer_class) do
      Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize state: ["active", "inactive"]
        typelize review: ["auto_checking", "auto_check_passed", "human_approved"]
      end
    end

    it "converts string arrays to string literal unions in keyed form" do
      attrs = serializer_class._typelizer_attributes[:state]
      expect(attrs[:type]).to eq([:"'active'", :"'inactive'"])
    end

    it "handles multiple string values" do
      attrs = serializer_class._typelizer_attributes[:review]
      expect(attrs[:type]).to eq([:"'auto_checking'", :"'auto_check_passed'", :"'human_approved'"])
    end
  end

  describe "'?' suffix on attribute keys" do
    it "treats trailing '?' on key as optional: true" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize name?: :string
      end

      attrs = serializer_class._typelizer_attributes[:name]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:optional]).to be true
    end

    it "composes with type shortcut (stays optional)" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize nickname?: "string?"
      end

      attrs = serializer_class._typelizer_attributes[:nickname]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:optional]).to be true
    end

    it "explicit optional: false in caller wins" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize name?: [:string, optional: false]
      end

      attrs = serializer_class._typelizer_attributes[:name]
      expect(attrs[:type]).to eq(:string)
      expect(attrs[:optional]).to be false
    end

    it "applies to typelize_meta" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize_meta total?: :number
      end

      attrs = serializer_class._typelizer_meta_attributes[:total]
      expect(attrs[:type]).to eq(:number)
      expect(attrs[:optional]).to be true
    end
  end

  describe "inline shape via positional hash" do
    it "parses a hash into a Shape value" do
      result = described_class.parse({id: :number, name: :string})
      expect(result[:type]).to be_a(Typelizer::Shape)
      expect(result[:type].properties.map(&:name)).to eq([:id, :name])
      expect(result[:type].properties.map(&:type)).to eq([:number, :string])
    end

    it "applies '?' suffix to shape keys" do
      result = described_class.parse({id: :number, name?: :string})
      prop = result[:type].properties.find { |p| p.name == :name }
      expect(prop.optional).to be true
    end

    it "recurses for nested hashes" do
      result = described_class.parse({user: {name: :string, age?: :number}})
      outer = result[:type]
      inner_prop = outer.properties.first
      expect(inner_prop.name).to eq(:user)
      expect(inner_prop.type).to be_a(Typelizer::Shape)
      age = inner_prop.type.properties.find { |p| p.name == :age }
      expect(age.optional).to be true
    end

    it "honors type shortcuts inside shape values" do
      result = described_class.parse({tags: "string[]", status: "string?"})
      tags = result[:type].properties.find { |p| p.name == :tags }
      status = result[:type].properties.find { |p| p.name == :status }
      expect(tags.multi).to be true
      expect(status.optional).to be true
    end

    it "merges outer options (multi, nullable) onto the shape" do
      result = described_class.parse({id: :number}, multi: true, nullable: true)
      expect(result[:type]).to be_a(Typelizer::Shape)
      expect(result[:multi]).to be true
      expect(result[:nullable]).to be true
    end
  end

  describe "keyless typelize with positional hash" do
    it "produces a Shape as the keyless type" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize({id: :number, name?: :string})
      end

      type, options = serializer_class.keyless_type
      expect(type).to be_a(Typelizer::Shape)
      expect(options).to eq({})
      names = type.properties.map(&:name)
      expect(names).to eq([:id, :name])
      name_prop = type.properties.find { |p| p.name == :name }
      expect(name_prop.optional).to be true
    end

    it "accepts options after the hash" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize({id: :number}, multi: true, nullable: true)
      end

      type, options = serializer_class.keyless_type
      expect(type).to be_a(Typelizer::Shape)
      expect(options[:multi]).to be true
      expect(options[:nullable]).to be true
    end
  end

  describe "keyless typelize with string literal arrays" do
    it "parses string array as string literal union" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize ["active", "inactive"]
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq([:"'active'", :"'inactive'"])
      expect(options).to eq({})
    end
  end

  describe "keyless typelize integration" do
    it "parses shortcuts in keyless typelize" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize "string?"
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq(:string)
      expect(options[:optional]).to be true
    end

    it "parses multi shortcut in keyless typelize" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize "User[]"
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq(:User)
      expect(options[:multi]).to be true
    end

    it "parses array type in keyless typelize" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize [:string, :number]
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq([:string, :number])
      expect(options).to eq({})
    end

    it "parses union string in keyless typelize" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize "'a' | 'b'"
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq([:"'a'", :"'b'"])
      expect(options).to eq({})
    end

    it "merges keyless typelize with explicit options" do
      serializer_class = Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize "string?", comment: "A field"
      end

      type, options = serializer_class.keyless_type
      expect(type).to eq(:string)
      expect(options[:optional]).to be true
      expect(options[:comment]).to eq("A field")
    end
  end

  describe ".parse" do
    context "with simple types" do
      it "parses a string type" do
        expect(described_class.parse("string")).to eq({type: :string})
      end

      it "parses a symbol type" do
        expect(described_class.parse(:number)).to eq({type: :number})
      end

      it "returns options when type_def is nil" do
        expect(described_class.parse(nil, foo: :bar)).to eq({foo: :bar})
      end
    end

    context "with optional modifier (?)" do
      it "parses 'string?' as optional" do
        expect(described_class.parse("string?")).to eq({type: :string, optional: true})
      end

      it "parses :number? as optional" do
        expect(described_class.parse(:number?)).to eq({type: :number, optional: true})
      end

      it "parses 'CustomType?' as optional" do
        expect(described_class.parse("CustomType?")).to eq({type: :CustomType, optional: true})
      end
    end

    context "with multi modifier ([])" do
      it "parses 'string[]' as multi" do
        expect(described_class.parse("string[]")).to eq({type: :string, multi: true})
      end

      it "parses :number[] as multi" do
        expect(described_class.parse(:"number[]")).to eq({type: :number, multi: true})
      end

      it "parses 'User[]' as multi" do
        expect(described_class.parse("User[]")).to eq({type: :User, multi: true})
      end
    end

    context "with combined modifiers" do
      it "parses 'string?[]' as optional and multi" do
        expect(described_class.parse("string?[]")).to eq({type: :string, optional: true, multi: true})
      end

      it "parses 'string[]?' as optional and multi" do
        expect(described_class.parse("string[]?")).to eq({type: :string, optional: true, multi: true})
      end

      it "parses :CustomType?[] as optional and multi" do
        expect(described_class.parse(:"CustomType?[]")).to eq({type: :CustomType, optional: true, multi: true})
      end
    end

    context "with Array input" do
      it "parses array of types into a union" do
        expect(described_class.parse([:string, :number])).to eq({type: [:string, :number]})
      end

      it "extracts null from symbol array to set nullable" do
        expect(described_class.parse([:string, :null])).to eq({type: :string, nullable: true})
      end

      it "preserves string literal types in array" do
        expect(described_class.parse([:"'cloudpayments'", :"'tiptoppay'"])).to eq({type: [:"'cloudpayments'", :"'tiptoppay'"]})
      end

      it "unwraps single-element array after null extraction" do
        expect(described_class.parse([:number, :null])).to eq({type: :number, nullable: true})
      end

      it "merges additional options with array input" do
        expect(described_class.parse([:string, :number], optional: true)).to eq({type: [:string, :number], optional: true})
      end

      it "raises on empty arrays" do
        expect { described_class.parse([]) }.to raise_error(ArgumentError, /Empty array/)
      end
    end

    context "with String array input (string literal unions)" do
      it "converts string arrays to string literal types" do
        expect(described_class.parse(["active", "inactive"])).to eq({type: [:"'active'", :"'inactive'"]})
      end

      it "handles single-element string arrays" do
        expect(described_class.parse(["active"])).to eq({type: :"'active'"})
      end

      it "treats 'null' as a literal string, not nullable" do
        expect(described_class.parse(["active", "null"])).to eq({type: [:"'active'", :"'null'"]})
      end

      it "preserves options for string arrays" do
        expect(described_class.parse(["active", "inactive"], optional: true)).to eq({type: [:"'active'", :"'inactive'"], optional: true})
      end

      it "handles mixed string and symbol arrays" do
        expect(described_class.parse([:number, "auto"])).to eq({type: [:number, :"'auto'"]})
      end

      it "handles mixed string and class arrays" do
        expect(described_class.parse([Integer, "pending"])).to eq({type: [:Integer, :"'pending'"]})
      end
    end

    context "with additional options" do
      it "merges additional options" do
        result = described_class.parse("string?", nullable: true, comment: "A comment")
        expect(result).to eq({type: :string, optional: true, nullable: true, comment: "A comment"})
      end

      it "allows explicit options to override parsed modifiers" do
        result = described_class.parse("string?", optional: false)
        expect(result).to eq({type: :string, optional: false})
      end
    end
  end

  describe ".shortcut?" do
    it "returns true for types ending with ?" do
      expect(described_class.shortcut?("string?")).to be true
    end

    it "returns true for types ending with []" do
      expect(described_class.shortcut?("string[]")).to be true
    end

    it "returns true for types ending with []?" do
      expect(described_class.shortcut?("string[]?")).to be true
    end

    it "returns false for plain types" do
      expect(described_class.shortcut?("string")).to be false
    end

    it "returns false for nil" do
      expect(described_class.shortcut?(nil)).to be false
    end

    it "returns false for symbols without modifiers" do
      expect(described_class.shortcut?(:string)).to be false
    end

    it "returns true for symbols with modifiers" do
      expect(described_class.shortcut?(:string?)).to be true
    end
  end
end
