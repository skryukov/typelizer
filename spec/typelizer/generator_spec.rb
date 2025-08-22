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
