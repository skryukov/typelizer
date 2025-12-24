# frozen_string_literal: true

RSpec.describe Typelizer::PropertySorter do
  def make_prop(name, type: :string)
    Typelizer::Property.new(name: name, type: type)
  end

  describe ".sort" do
    let(:props) { [make_prop("zebra"), make_prop("apple"), make_prop("id"), make_prop("banana")] }

    describe "with :none" do
      it "preserves original order" do
        result = described_class.sort(props, :none)
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end
    end

    describe "with nil" do
      it "preserves original order" do
        result = described_class.sort(props, nil)
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end
    end

    describe "with :alphabetical" do
      it "sorts properties alphabetically (case-insensitive)" do
        result = described_class.sort(props, :alphabetical)
        expect(result.map(&:name)).to eq(%w[apple banana id zebra])
      end

      it "handles mixed case names" do
        mixed_props = [make_prop("Zebra"), make_prop("apple"), make_prop("Apple")]
        result = described_class.sort(mixed_props, :alphabetical)
        expect(result.map(&:name)).to eq(%w[apple Apple Zebra])
      end

      it "handles empty array" do
        result = described_class.sort([], :alphabetical)
        expect(result).to eq([])
      end
    end

    describe "with :id_first_alphabetical" do
      it "places id first, then sorts remaining alphabetically" do
        result = described_class.sort(props, :id_first_alphabetical)
        expect(result.map(&:name)).to eq(%w[id apple banana zebra])
      end

      it "handles different id casings (Id, ID)" do
        mixed_id_props = [make_prop("name"), make_prop("Id"), make_prop("id"), make_prop("ID")]
        result = described_class.sort(mixed_id_props, :id_first_alphabetical)
        # All id variants should come first
        expect(result.map(&:name).first(3)).to all(match(/^id$/i))
        expect(result.map(&:name).last).to eq("name")
      end

      it "works when id is not present" do
        no_id_props = [make_prop("zebra"), make_prop("apple")]
        result = described_class.sort(no_id_props, :id_first_alphabetical)
        expect(result.map(&:name)).to eq(%w[apple zebra])
      end
    end

    describe "with Proc" do
      it "applies custom sorting logic" do
        reverse_sort = ->(p) { p.sort_by { |prop| prop.name.to_s }.reverse }
        result = described_class.sort(props, reverse_sort)
        expect(result.map(&:name)).to eq(%w[zebra id banana apple])
      end

      it "falls back to original order when proc returns nil" do
        result = described_class.sort(props, ->(_) {})
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end

      it "falls back to original order when proc returns non-array" do
        result = described_class.sort(props, ->(_) { "wrong" })
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end

      it "falls back to original order when proc raises error" do
        expect(Typelizer.logger).to receive(:warn).with(/PropertySorter error/)
        result = described_class.sort(props, ->(_) { raise "boom" })
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end
    end

    describe "with unknown sort_order" do
      it "preserves original order" do
        result = described_class.sort(props, :unknown_strategy)
        expect(result.map(&:name)).to eq(%w[zebra apple id banana])
      end
    end

    describe "edge cases" do
      it "handles symbol names" do
        symbol_props = [make_prop(:beta), make_prop(:alpha)]
        result = described_class.sort(symbol_props, :alphabetical)
        expect(result.map(&:name)).to eq([:alpha, :beta])
      end

      it "handles numeric-like names (lexicographic sort)" do
        numeric_props = [make_prop("item2"), make_prop("item10"), make_prop("item1")]
        result = described_class.sort(numeric_props, :alphabetical)
        # Lexicographic, not natural sort
        expect(result.map(&:name)).to eq(%w[item1 item10 item2])
      end

      it "handles special characters" do
        special_props = [make_prop("_private"), make_prop("$special"), make_prop("normal")]
        result = described_class.sort(special_props, :alphabetical)
        expect(result.map(&:name)).to eq(%w[$special _private normal])
      end
    end
  end
end
