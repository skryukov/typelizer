# frozen_string_literal: true

RSpec.describe Typelizer::Property do
  describe "#to_s" do
    describe "union type sorting" do
      it "does not sort unions when sort_order is :none" do
        prop = described_class.new(name: "field", type: "TypeZ | TypeA | TypeB")
        expect(prop.render(sort_order: :none)).to eq("field: TypeZ | TypeA | TypeB")
      end

      it "sorts unions alphabetically when sort_order is :alphabetical" do
        prop = described_class.new(name: "field", type: "TypeZ | TypeA | TypeB")
        expect(prop.render(sort_order: :alphabetical)).to eq("field: TypeA | TypeB | TypeZ")
      end

      it "sorts unions in Array<> types" do
        prop = described_class.new(name: "items", type: "TypeZ | TypeA | TypeB", multi: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("items: Array<TypeA | TypeB | TypeZ>")
      end

      it "keeps null at the end when nullable" do
        prop = described_class.new(name: "field", type: "TypeZ | TypeA", nullable: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("field: TypeA | TypeZ | null")
      end

      it "handles enum values with sorting" do
        prop = described_class.new(name: "status", enum: %w[zebra apple banana])
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq('status: "apple" | "banana" | "zebra"')
      end

      it "does not sort enum values when sort_order is :none" do
        prop = described_class.new(name: "status", enum: %w[zebra apple banana])
        result = prop.render(sort_order: :none)
        expect(result).to eq('status: "zebra" | "apple" | "banana"')
      end

      it "defaults to no sorting when sort_order not specified" do
        prop = described_class.new(name: "field", type: "TypeZ | TypeA | TypeB")
        expect(prop.to_s).to eq("field: TypeZ | TypeA | TypeB")
      end
    end

    describe "optional properties" do
      it "adds ? for optional properties" do
        prop = described_class.new(name: "field", type: "string", optional: true)
        expect(prop.to_s).to eq("field?: string")
      end
    end

    describe "nullable properties" do
      it "adds | null for nullable properties" do
        prop = described_class.new(name: "field", type: "string", nullable: true)
        expect(prop.to_s).to eq("field: string | null")
      end
    end

    describe "multi (array) properties" do
      it "wraps type in Array<> for multi properties" do
        prop = described_class.new(name: "items", type: "string", multi: true)
        expect(prop.to_s).to eq("items: Array<string>")
      end
    end

    describe "combined modifiers" do
      it "handles optional, nullable, and multi together" do
        prop = described_class.new(name: "items", type: "string", optional: true, nullable: true, multi: true)
        expect(prop.to_s).to eq("items?: Array<string> | null")
      end

      it "handles union type with optional, nullable, and multi" do
        prop = described_class.new(name: "items", type: "TypeZ | TypeA", optional: true, nullable: true, multi: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("items?: Array<TypeA | TypeZ> | null")
      end
    end
  end

  describe "determinism" do
    it "produces identical output on multiple runs with sorting" do
      prop = described_class.new(
        name: "sections",
        type: "WebStrapiSectionsPartnerHero | WebStrapiSectionsAboutUs | WebStrapiSectionsChallenges",
        multi: true
      )

      results = 10.times.map { prop.render(sort_order: :alphabetical) }
      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq("sections: Array<WebStrapiSectionsAboutUs | WebStrapiSectionsChallenges | WebStrapiSectionsPartnerHero>")
    end
  end
end
