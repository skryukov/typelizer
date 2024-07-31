# frozen_string_literal: true

RSpec.describe Typelizer do
  let(:config) { Typelizer::Config }

  around(:each) do |example|
    FileUtils.rmtree(config.output_dir)
    example.run
    FileUtils.rmtree(config.output_dir)
  end

  it "has a rake task available", aggregate_failures: true do
    Rails.application.load_tasks
    expect { Rake::Task["typelizer:generate"].invoke }.not_to raise_error

    # check all generated files are equal to the snapshots
    config.output_dir.glob("**/*.ts").each do |file|
      expect(file.read).to match_snapshot(file.basename)
    end
  end
end
