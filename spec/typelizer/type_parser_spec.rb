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
