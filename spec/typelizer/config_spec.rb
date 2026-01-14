# frozen_string_literal: true

RSpec.describe Typelizer::Config do
  describe "fingerprint config categorization" do
    it "categorizes all config keys" do
      all_config_keys = Typelizer::Config.members
      categorized_keys = Typelizer::CONFIGS_AFFECTING_OUTPUT + Typelizer::CONFIGS_NOT_AFFECTING_OUTPUT

      missing = all_config_keys - categorized_keys
      extra = categorized_keys - all_config_keys

      expect(missing).to be_empty,
        "Config keys not categorized for fingerprinting: #{missing.join(", ")}. " \
        "Add to CONFIGS_AFFECTING_OUTPUT or CONFIGS_NOT_AFFECTING_OUTPUT in config.rb"

      expect(extra).to be_empty,
        "Categorized keys that don't exist in Config: #{extra.join(", ")}"
    end

    it "has CONFIGS_AFFECTING_INDEX_OUTPUT as a subset of CONFIGS_AFFECTING_OUTPUT" do
      extra = Typelizer::CONFIGS_AFFECTING_INDEX_OUTPUT - Typelizer::CONFIGS_AFFECTING_OUTPUT

      expect(extra).to be_empty,
        "CONFIGS_AFFECTING_INDEX_OUTPUT contains keys not in CONFIGS_AFFECTING_OUTPUT: #{extra.join(", ")}"
    end
  end
end
