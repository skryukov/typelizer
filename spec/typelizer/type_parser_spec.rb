# frozen_string_literal: true

RSpec.describe Typelizer::TypeParser do
  describe "DSL integration" do
    let(:serializer_class) do
      Class.new do
        extend Typelizer::DSL::ClassMethods

        typelize name: "string?"
        typelize age: "number[]"
        typelize tags: "string?[]"
        typelize score: ["number?", nullable: true]
      end
    end

    it "parses optional shortcut in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:name]
      expect(attrs[:type]).to eq("string")
      expect(attrs[:optional]).to be true
    end

    it "parses multi shortcut in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:age]
      expect(attrs[:type]).to eq("number")
      expect(attrs[:multi]).to be true
    end

    it "parses combined shortcuts in typelize hash" do
      attrs = serializer_class._typelizer_attributes[:tags]
      expect(attrs[:type]).to eq("string")
      expect(attrs[:optional]).to be true
      expect(attrs[:multi]).to be true
    end

    it "merges shortcuts with explicit options" do
      attrs = serializer_class._typelizer_attributes[:score]
      expect(attrs[:type]).to eq("number")
      expect(attrs[:optional]).to be true
      expect(attrs[:nullable]).to be true
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
