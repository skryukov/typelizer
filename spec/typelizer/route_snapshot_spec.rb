# frozen_string_literal: true

RSpec.describe Typelizer::RouteGenerator do
  let(:output_dir) { Rails.root.join("tmp/route_snapshots") }
  let(:route_config) { Typelizer.configuration.routes }

  around(:each) do |example|
    route_config.enabled = true
    route_config.output_dir = output_dir
    FileUtils.rmtree(output_dir)
    example.run
    FileUtils.rmtree(output_dir)
    route_config.enabled = false
    route_config.output_dir = nil
    route_config.format = :ts
  end

  it "generates expected route files", aggregate_failures: true do
    described_class.call(force: true)

    output_dir.glob("**/*.ts").sort.each do |file|
      relative = file.relative_path_from(output_dir).to_s
      expect(file.read).to match_snapshot("routes/#{relative}")
    end
  end

  it "generates expected JS route files", aggregate_failures: true do
    route_config.format = :js
    described_class.call(force: true)

    output_dir.glob("**/*.js").sort.each do |file|
      relative = file.relative_path_from(output_dir).to_s
      expect(file.read).to match_snapshot("routes_js/#{relative}")
    end
  end
end
