# frozen_string_literal: true

require "json"
require "json_schemer"

RSpec.describe "OpenAPI schema validation" do
  # External types referenced via manual `typelize` overrides or union types
  # that don't have corresponding serializers in the test app.
  EXTERNAL_SCHEMAS = %w[
    AlphaSection
    BetaSection
    Post
    TypeA
    TypeM
    TypeZ
    ZebraSection
  ].freeze

  %w[3.0 3.1].each do |version|
    it "generates a valid OpenAPI #{version} document with all schemas" do
      schemas = Typelizer.openapi_schemas(openapi_version: version)
      EXTERNAL_SCHEMAS.each { |name| schemas[name] = {type: "object"} }

      openapi_version = (version == "3.0") ? "3.0.3" : "3.1.0"
      document = {
        openapi: openapi_version,
        info: {title: "Typelizer Test", version: "0.0.1"},
        paths: {},
        components: {schemas: schemas}
      }
      json = JSON.parse(JSON.generate(document))

      schemer = JSONSchemer.openapi(json)
      errors = schemer.validate.to_a

      if errors.any?
        details = errors.map { |e| "  #{e["data_pointer"]}: #{e["error"]}" }.join("\n")
        fail "#{errors.size} OpenAPI #{version} validation errors:\n#{details}"
      end
    end
  end
end
