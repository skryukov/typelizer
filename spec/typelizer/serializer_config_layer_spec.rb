# frozen_string_literal: true

RSpec.describe Typelizer::SerializerConfigLayer do
  subject(:layer) { described_class.new(target_hash) }

  let(:target_hash) { {} }

  describe "writer-only keys" do
    it "raises ArgumentError when setting output_dir" do
      expect {
        layer.send(:method_missing, "output_dir=", "/some/path")
      }.to raise_error(ArgumentError, /cannot be set per-serializer/)
    end

    it "includes guidance to use a named writer" do
      expect {
        layer.send(:method_missing, "output_dir=", "/some/path")
      }.to raise_error(ArgumentError, /config\.writer\(:name\)/)
    end

    it "still allows reading output_dir" do
      expect(layer.send(:method_missing, "output_dir")).to be_nil
    end
  end

  describe "WRITER_ONLY_KEYS is a subset of VALID_KEYS" do
    it "only contains valid config keys" do
      extra = described_class::WRITER_ONLY_KEYS - described_class::VALID_KEYS
      expect(extra).to be_empty,
        "WRITER_ONLY_KEYS contains keys not in Config.members: #{extra.to_a.join(", ")}"
    end
  end
end
