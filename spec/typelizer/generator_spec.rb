# frozen_string_literal: true

RSpec.describe Typelizer::Generator, type: :typelizer do
  let(:configuration) { Typelizer.configuration }
  let(:default_output_dir) { configuration.writer_config(:default).output_dir }
  let(:camel_case_output_dir) { default_output_dir.parent.join("generator_camel_case") }

  # camelCase transformer for a writer
  let(:camel_case_transformer) do
    lambda do |properties|
      properties.map do |prop|
        new_name = prop.name.to_s.camelize(:lower)
        prop.class.new(**prop.to_h.merge(name: new_name))
      end
    end
  end

  def restore_defaults!
    configuration.reset_writers!
    configuration.types_import_path = "@/types"
    configuration.prefer_double_quotes = false
  end

  around do |ex|
    restore_defaults!
    configuration.writer(:camel_case) do |c|
      c.output_dir = camel_case_output_dir
      c.properties_transformer = camel_case_transformer
    end

    ex.call

    restore_defaults!

    FileUtils.rm_rf(camel_case_output_dir)
  end

  describe "#call" do
    subject(:generator) { described_class.new }

    it "uses each writer's own reject_class so a serializer excluded by one writer still appears in another" do
      alba_only_dir = default_output_dir.parent.join("generator_alba_only")

      configuration.writer(:alba_only) do |c|
        c.output_dir = alba_only_dir
        c.reject_class = ->(serializer:) { !serializer.name.start_with?("Alba::") }
      end

      expect { generator.call(force: true) }.not_to raise_error

      # alba_only writer should have Alba files
      expect(alba_only_dir.join("AlbaPost.ts")).to exist

      # alba_only writer should NOT have non-Alba files
      expect(alba_only_dir.join("AmsPost.ts")).not_to exist

      # default writer should still have both
      expect(default_output_dir.join("AlbaPost.ts")).to exist
      expect(default_output_dir.join("AmsPost.ts")).to exist
    ensure
      FileUtils.rm_rf(alba_only_dir)
    end

    it "silently skips writers with no serializers" do
      configuration.writer(:empty) do |c|
        c.output_dir = default_output_dir.parent.join("generator_empty")
        c.reject_class = ->(**) { true }
      end

      expect { generator.call(force: true) }.not_to raise_error
    ensure
      FileUtils.rm_rf(default_output_dir.parent.join("generator_empty"))
    end

    it "writes interfaces to per-serializer output_dir" do
      custom_output_dir = Rails.root.join("app/javascript/types/custom_output")

      generator.call(force: true)

      # File lands in the custom output_dir, not the default
      expect(custom_output_dir.join("AlbaCustomOutputDir.ts")).to exist
      expect(default_output_dir.join("AlbaCustomOutputDir.ts")).not_to exist

      # index.ts in the writer's default output_dir still re-exports it
      index_content = File.read(default_output_dir.join("index.ts"))
      expect(index_content).to include("AlbaCustomOutputDir")
    ensure
      FileUtils.rm_rf(custom_output_dir)
    end

    it "uses filename_mapper to generate nested file paths" do
      nested_dir = default_output_dir.parent.join("generator_nested")

      configuration.writer(:nested) do |c|
        c.output_dir = nested_dir
        c.filename_mapper = ->(name) { name.gsub("::", "/") }
      end

      generator.call(force: true)

      # Alba::UserSerializer mapped name is "Alba::User", filename becomes "Alba/User"
      expect(nested_dir.join("Alba/User.ts")).to exist
      expect(nested_dir.join("AlbaUser.ts")).not_to exist

      # Type name in index.ts is still flat
      index_content = File.read(nested_dir.join("index.ts"))
      expect(index_content).to include("AlbaUser")
      expect(index_content).to include("'./Alba/User'")
    ensure
      FileUtils.rm_rf(nested_dir)
    end

    it "generates files for all writers and applies writer-specific transformers" do
      expect { generator.call(force: true) }.not_to raise_error

      expect(default_output_dir).to be_directory
      expect(camel_case_output_dir).to be_directory

      # Base (snake_case) must keep snake case field names
      base_post = default_output_dir.join("AlbaPost.ts")
      expect(base_post).to exist
      base_content = File.read(base_post)
      expect(base_content).to include("next_post: Post")
      expect(base_content).not_to include("nextPost: Post")

      # Camel writer must apply camelCase transform
      camel_post = camel_case_output_dir.join("AlbaPost.ts")
      expect(camel_post).to exist
      camel_content = File.read(camel_post)
      expect(camel_content).to include("nextPost: Post")
      expect(camel_content).not_to include("next_post: Post")
    end
  end
end
