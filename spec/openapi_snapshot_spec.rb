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
        end
      end
    end
  end
end
