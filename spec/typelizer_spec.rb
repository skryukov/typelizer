# frozen_string_literal: true

RSpec.describe Typelizer do
  let(:output_dir) { Typelizer::Config.default_output_dir }
  let(:custom_output_dir) { Rails.root.join("app/javascript/types/custom_output") }
  let(:camel_case_output_dir) { CamelCaseWriterFixture.output_dir }
  let(:runtime_enums_output_dir) { RuntimeEnumsWriterFixture.output_dir }

  around(:each) do |example|
    # Sibling specs call `reset_writers!` and may leave fixture writers unregistered.
    CamelCaseWriterFixture.register!(Typelizer.configuration)
    RuntimeEnumsWriterFixture.register!(Typelizer.configuration)

    FileUtils.rmtree(output_dir)
    FileUtils.rmtree(custom_output_dir)
    FileUtils.rmtree(camel_case_output_dir)
    FileUtils.rmtree(runtime_enums_output_dir)
    example.run
    FileUtils.rmtree(output_dir)
    FileUtils.rmtree(custom_output_dir)
    FileUtils.rmtree(camel_case_output_dir)
    FileUtils.rmtree(runtime_enums_output_dir)
  end

  it "has a rake task available", aggregate_failures: true do
    Rails.application.load_tasks
    expect { Rake::Task["typelizer:generate"].invoke }.not_to raise_error

    # check all generated files are equal to the snapshots
    all_files = output_dir.glob("**/*.ts") + custom_output_dir.glob("**/*.ts")
    all_files.each do |file|
      expect(file.read).to match_snapshot(file.basename)
    end

    camel_case_files = camel_case_output_dir.glob("**/*.ts")
    expect(camel_case_files).not_to be_empty, "camel_case writer produced no output — transformer coverage lost"
    camel_case_files.each do |file|
      expect(file.read).to match_snapshot("camel_case/#{file.basename}")
    end

    runtime_enums_files = runtime_enums_output_dir.glob("**/*.ts")
    expect(runtime_enums_files).not_to be_empty, "runtime_enums writer produced no output — runtime enums coverage lost"
    runtime_enums_files.each do |file|
      expect(file.read).to match_snapshot("runtime_enums/#{file.basename}")
    end
  end
end
