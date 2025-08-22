# frozen_string_literal: true

RSpec.describe Typelizer do
  let(:output_dir) { Typelizer::Config.default_output_dir }

  around(:each) do |example|
    FileUtils.rmtree(output_dir)
    example.run
    FileUtils.rmtree(output_dir)
  end

  it "has a rake task available", aggregate_failures: true do
    Rails.application.load_tasks
    expect { Rake::Task["typelizer:generate"].invoke }.not_to raise_error

    # check all generated files are equal to the snapshots
    output_dir.glob("**/*.ts").each do |file|
      expect(file.read).to match_snapshot(file.basename)
    end
  end
end
