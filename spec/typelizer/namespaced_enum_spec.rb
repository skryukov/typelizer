# frozen_string_literal: true

RSpec.describe "Enums of namespaced models" do
  let(:context) { Typelizer::WriterContext.new }
  let(:output_dir) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(output_dir) }

  def build_model(name, values)
    stub_const(name, Class.new(ApplicationRecord) do
      self.table_name = "posts"

      enum :category, values
    end)
  end

  def build_resource(name, model)
    stub_const(name, Class.new do
      include ::Alba::Resource

      helper Typelizer::DSL

      typelize_from model
      attributes :category
    end)
  end

  def generate_enums(*resources)
    interfaces = resources.map { |resource| context.interface_for(resource) }
    config = context.writer_config.with_overrides(output_dir: output_dir)
    Typelizer::Writer.new(config).call(interfaces, force: false)

    output_dir.join("Enums.ts").read
  end

  before do
    stub_const("Course", Module.new)
    stub_const("Project", Module.new)
  end

  it "keeps the namespace in the enum type name" do
    resource = build_resource("CourseBuildResource", build_model("Course::Build", {pending: 0, done: 1}))

    prop = context.interface_for(resource).properties.find { |p| p.name == "category" }

    expect(prop.render).to eq("category: CourseBuildCategory | null")
  end

  it "generates both enums for models that share a class name" do
    course = build_resource("CourseBuildResource", build_model("Course::Build", {pending: 0, done: 1}))
    project = build_resource("ProjectBuildResource", build_model("Project::Build", {queued: 0, failed: 1}))

    expect(Typelizer.logger).not_to receive(:warn)

    enums = generate_enums(course, project)

    expect(enums).to include("export type CourseBuildCategory = 'pending' | 'done'")
    expect(enums).to include("export type ProjectBuildCategory = 'queued' | 'failed'")
  end

  it "warns when two enums still resolve to the same name with different values" do
    nested = build_resource("NestedBuildResource", build_model("Course::Build", {pending: 0, done: 1}))
    flat = build_resource("FlatBuildResource", build_model("CourseBuild", {queued: 0, failed: 1}))

    expect(Typelizer.logger).to receive(:warn).with(/CourseBuildCategory has conflicting values/)

    generate_enums(nested, flat)
  end

  it "does not warn when the same enum is used by several serializers" do
    model = build_model("Course::Build", {pending: 0, done: 1})
    first = build_resource("FirstBuildResource", model)
    second = build_resource("SecondBuildResource", model)

    expect(Typelizer.logger).not_to receive(:warn)

    generate_enums(first, second)
  end
end
