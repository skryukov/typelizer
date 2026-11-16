# frozen_string_literal: true

RSpec.describe "Enums of namespaced models" do
  let(:context) { Typelizer::WriterContext.new }

  before do
    stub_const("Course", Module.new)
    stub_const("Project", Module.new)
  end

  # An interface exposing the `category` enum of a new model
  def interface_for(model_name, values)
    model = stub_const(model_name, Class.new(ApplicationRecord) do
      self.table_name = "posts"
      enum :category, values
    end)

    @resources = @resources.to_i + 1
    context.interface_for(stub_const("Enum#{@resources}Resource", Class.new do
      include ::Alba::Resource

      helper Typelizer::DSL
      typelize_from model
      attributes :category
    end))
  end

  def enum_names(*interfaces)
    interfaces.flat_map(&:enum_types).map(&:enum_type_name)
  end

  it "keeps the namespace in the enum type name" do
    course = interface_for("Course::Build", {pending: 0, done: 1})
    project = interface_for("Project::Build", {queued: 0, failed: 1})

    expect(enum_names(course, project)).to eq(%w[CourseBuildCategory ProjectBuildCategory])
  end

  it "warns when two different enums still get the same name" do
    interfaces = [
      interface_for("Course::Build", {pending: 0, done: 1}),
      interface_for("CourseBuild", {queued: 0, failed: 1})
    ]

    expect(Typelizer.logger).to receive(:warn).with(/CourseBuildCategory has conflicting values/)

    Dir.mktmpdir do |dir|
      config = context.writer_config.with_overrides(output_dir: Pathname.new(dir))
      Typelizer::Writer.new(config).call(interfaces, force: false)
    end
  end
end
