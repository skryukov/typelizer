# frozen_string_literal: true

RSpec.describe Typelizer::UnionTypeSorter do
  describe ".sort" do
    describe "with :none" do
      it "preserves original order" do
        result = described_class.sort("Zebra | Apple | Banana", :none)
        expect(result).to eq("Zebra | Apple | Banana")
      end
    end

    describe "with nil" do
      it "preserves original order" do
        result = described_class.sort("Zebra | Apple | Banana", nil)
        expect(result).to eq("Zebra | Apple | Banana")
      end
    end

    describe "with :alphabetical" do
      it "sorts simple union types alphabetically" do
        result = described_class.sort("Zebra | Apple | Banana", :alphabetical)
        expect(result).to eq("Apple | Banana | Zebra")
      end

      it "sorts case-insensitively" do
        result = described_class.sort("zebra | Apple | BANANA", :alphabetical)
        expect(result).to eq("Apple | BANANA | zebra")
      end

      it "keeps null at the end" do
        result = described_class.sort("Zebra | null | Apple", :alphabetical)
        expect(result).to eq("Apple | Zebra | null")
      end

      it "handles unions inside Array<>" do
        result = described_class.sort("Array<Zebra | Apple | Banana>", :alphabetical)
        expect(result).to eq("Array<Apple | Banana | Zebra>")
      end

      it "handles complex nested generics" do
        result = described_class.sort("Array<TypeC | TypeA | TypeB>", :alphabetical)
        expect(result).to eq("Array<TypeA | TypeB | TypeC>")
      end

      it "handles empty string" do
        result = described_class.sort("", :alphabetical)
        expect(result).to eq("")
      end

      it "handles nil" do
        result = described_class.sort(nil, :alphabetical)
        expect(result).to be_nil
      end

      it "handles single type (no union)" do
        result = described_class.sort("SingleType", :alphabetical)
        expect(result).to eq("SingleType")
      end

      it "handles types with numbers" do
        result = described_class.sort("Type3 | Type1 | Type2", :alphabetical)
        expect(result).to eq("Type1 | Type2 | Type3")
      end

      it "preserves whitespace style" do
        result = described_class.sort("Zebra | Apple | Banana", :alphabetical)
        expect(result).to eq("Apple | Banana | Zebra")
      end
    end

    describe "with Proc" do
      it "applies custom sorting logic" do
        reverse_sort = ->(type_str) { type_str.split(" | ").reverse.join(" | ") }
        result = described_class.sort("A | B | C", reverse_sort)
        expect(result).to eq("C | B | A")
      end

      it "falls back to original when proc returns nil" do
        result = described_class.sort("A | B", ->(_) {})
        expect(result).to eq("A | B")
      end

      it "falls back to original when proc returns non-string" do
        result = described_class.sort("A | B", ->(_) { 123 })
        expect(result).to eq("A | B")
      end

      it "falls back to original when proc raises error" do
        expect(Typelizer.logger).to receive(:warn).with(/UnionTypeSorter error/)
        result = described_class.sort("A | B", ->(_) { raise "boom" })
        expect(result).to eq("A | B")
      end
    end

    describe "with unknown sort_order" do
      it "preserves original order" do
        result = described_class.sort("Zebra | Apple", :unknown_strategy)
        expect(result).to eq("Zebra | Apple")
      end
    end
  end

  describe ".split_union_members" do
    it "splits simple unions" do
      result = described_class.split_union_members("A | B | C")
      expect(result).to eq(%w[A B C])
    end

    it "respects nested angle brackets" do
      result = described_class.split_union_members("Array<A | B> | C")
      expect(result).to eq(["Array<A | B>", "C"])
    end

    it "respects nested parentheses" do
      result = described_class.split_union_members("(A | B) | C")
      expect(result).to eq(["(A | B)", "C"])
    end

    it "handles complex nesting" do
      result = described_class.split_union_members("Map<string, Array<A | B>> | C | D")
      expect(result).to eq(["Map<string, Array<A | B>>", "C", "D"])
    end
  end

  describe ".balanced_brackets?" do
    it "returns true for balanced brackets" do
      expect(described_class.balanced_brackets?("Array<Type>")).to be true
      expect(described_class.balanced_brackets?("Map<K, V>")).to be true
      expect(described_class.balanced_brackets?("(A | B)")).to be true
    end

    it "returns false for unbalanced brackets" do
      expect(described_class.balanced_brackets?("Array<Type")).to be false
      expect(described_class.balanced_brackets?("Type>")).to be false
      expect(described_class.balanced_brackets?("(A | B")).to be false
    end
  end

  describe "determinism" do
    it "produces identical output on multiple runs" do
      input = "WebStrapiSectionsPartnerHero | WebStrapiSectionsAboutUs | WebStrapiSectionsChallenges"
      results = 10.times.map { described_class.sort(input, :alphabetical) }
      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq("WebStrapiSectionsAboutUs | WebStrapiSectionsChallenges | WebStrapiSectionsPartnerHero")
    end

    it "produces identical output for Array unions on multiple runs" do
      input = "Array<TypeZ | TypeA | TypeM | TypeB>"
      results = 10.times.map { described_class.sort(input, :alphabetical) }
      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq("Array<TypeA | TypeB | TypeM | TypeZ>")
    end
  end
end
