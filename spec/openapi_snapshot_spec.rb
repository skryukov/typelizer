# frozen_string_literal: true

require "json"

RSpec.describe Typelizer::OpenAPI, "snapshots" do
  %w[3.0 3.1].each do |version|
    context "OpenAPI #{version}" do
      it "generates expected schemas for all interfaces", aggregate_failures: true do
        Typelizer.interfaces.each do |interface|
          schema = described_class.schema_for(interface, openapi_version: version)
          json = JSON.pretty_generate(schema)
          expect(json).to match_snapshot("#{interface.name}.openapi#{version}.json")

          interface.trait_interfaces.each do |trait|
            trait_schema = described_class.schema_for(trait, openapi_version: version)
            trait_json = JSON.pretty_generate(trait_schema)
            expect(trait_json).to match_snapshot("#{trait.name}.openapi#{version}.json")
          end
        end
      end
    end
  end
end
