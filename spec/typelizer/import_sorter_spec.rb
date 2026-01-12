# frozen_string_literal: true

RSpec.describe Typelizer::ImportSorter do
  describe ".sort" do
    let(:imports) { %w[Zebra Apple User Banana] }

    describe "with :none" do
      it "preserves original order" do
        result = described_class.sort(imports, :none)
        expect(result).to eq(%w[Zebra Apple User Banana])
      end
    end

    describe "with nil" do
      it "preserves original order" do
        result = described_class.sort(imports, nil)
        expect(result).to eq(%w[Zebra Apple User Banana])
      end
    end

    describe "with :alphabetical" do
      it "sorts imports alphabetically (case-insensitive)" do
        result = described_class.sort(imports, :alphabetical)
        expect(result).to eq(%w[Apple Banana User Zebra])
      end

      it "handles mixed case names" do
        mixed_imports = %w[zebra Apple apple]
        result = described_class.sort(mixed_imports, :alphabetical)
        expect(result).to eq(%w[Apple apple zebra])
      end

      it "handles empty array" do
        result = described_class.sort([], :alphabetical)
        expect(result).to eq([])
      end
    end

    describe "with Proc" do
      it "applies custom sorting logic" do
        reverse_sort = ->(i) { i.sort.reverse }
        result = described_class.sort(imports, reverse_sort)
        expect(result).to eq(%w[Zebra User Banana Apple])
      end

      it "falls back to original order when proc returns nil" do
        result = described_class.sort(imports, ->(_) {})
        expect(result).to eq(%w[Zebra Apple User Banana])
      end

      it "falls back to original order when proc returns non-array" do
        result = described_class.sort(imports, ->(_) { "wrong" })
        expect(result).to eq(%w[Zebra Apple User Banana])
      end

      it "falls back to original order when proc raises error" do
        expect(Typelizer.logger).to receive(:warn).with(/ImportSorter error/)
        result = described_class.sort(imports, ->(_) { raise "boom" })
        expect(result).to eq(%w[Zebra Apple User Banana])
      end
    end

    describe "with unknown sort_order" do
      it "preserves original order" do
        result = described_class.sort(imports, :unknown_strategy)
        expect(result).to eq(%w[Zebra Apple User Banana])
      end
    end

    describe "edge cases" do
      it "handles symbol imports" do
        symbol_imports = [:Beta, :Alpha]
        result = described_class.sort(symbol_imports, :alphabetical)
        expect(result).to eq([:Alpha, :Beta])
      end

      it "handles numeric-like names (lexicographic sort)" do
        numeric_imports = %w[Item2 Item10 Item1]
        result = described_class.sort(numeric_imports, :alphabetical)
        # Lexicographic, not natural sort
        expect(result).to eq(%w[Item1 Item10 Item2])
      end
    end
  end
end
