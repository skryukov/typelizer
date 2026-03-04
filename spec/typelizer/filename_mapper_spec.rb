# frozen_string_literal: true

RSpec.describe "filename_mapper", type: :typelizer do
  let(:configuration) { Typelizer.configuration }
  let(:default_output_dir) { configuration.writer_config(:default).output_dir }
  let(:nested_output_dir) { default_output_dir.parent.join("filename_mapper_nested") }

  let(:namespace_mapper) do
    lambda do |serializer|
      serializer.name.to_s
        .sub(/(Serializer|Resource)\z/, "")
        .gsub("::", "/")
    end
  end

  def restore_defaults!
    configuration.reset_writers!
    configuration.types_import_path = "@/types"
    configuration.prefer_double_quotes = false
  end

  around do |ex|
    restore_defaults!
    ex.call
    restore_defaults!
  end

  describe "default behavior (no filename_mapper)" do
    it "produces flat filenames derived from name" do
      context = Typelizer::WriterContext.new
      interface = context.interface_for(Alba::UserSerializer)

      expect(interface.name).to eq("AlbaUser")
      expect(interface.filename).to eq("AlbaUser")
    end
  end

  describe "with filename_mapper configured" do
    it "uses the mapper to produce nested filenames" do
      configuration.writer(:nested) do |c|
        c.output_dir = nested_output_dir
        c.filename_mapper = namespace_mapper
      end

      context = Typelizer::WriterContext.new(writer_name: :nested)
      interface = context.interface_for(Alba::UserSerializer)

      expect(interface.name).to eq("AlbaUser")
      expect(interface.filename).to eq("Alba/User")
    end

    it "generates files in nested directories" do
      configuration.writer(:nested) do |c|
        c.output_dir = nested_output_dir
        c.filename_mapper = namespace_mapper
      end

      generator = Typelizer::Generator.new
      expect { generator.call(force: true) }.not_to raise_error

      expect(nested_output_dir.join("Alba/User.ts")).to exist
      expect(nested_output_dir.join("Alba/Post.ts")).to exist
    ensure
      FileUtils.rm_rf(nested_output_dir)
      FileUtils.rm_rf(default_output_dir)
    end

    it "generates index.ts with nested paths but flat type names" do
      configuration.writer(:nested) do |c|
        c.output_dir = nested_output_dir
        c.filename_mapper = namespace_mapper
      end

      generator = Typelizer::Generator.new
      generator.call(force: true)

      index_content = File.read(nested_output_dir.join("index.ts"))

      expect(index_content).to include("Alba/User")
      expect(index_content).to include("as AlbaUser")
    ensure
      FileUtils.rm_rf(nested_output_dir)
      FileUtils.rm_rf(default_output_dir)
    end
  end

  describe "stale file and empty directory cleanup" do
    it "removes stale files in nested directories" do
      configuration.writer(:nested) do |c|
        c.output_dir = nested_output_dir
        c.filename_mapper = namespace_mapper
      end

      generator = Typelizer::Generator.new
      generator.call(force: true)

      stale_file = nested_output_dir.join("Stale/Nested/OldType.ts")
      FileUtils.mkdir_p(stale_file.dirname)
      File.write(stale_file, "// stale")

      generator.call(force: false)

      expect(stale_file).not_to exist
    ensure
      FileUtils.rm_rf(nested_output_dir)
      FileUtils.rm_rf(default_output_dir)
    end

    it "removes empty parent directories after stale file deletion" do
      configuration.writer(:nested) do |c|
        c.output_dir = nested_output_dir
        c.filename_mapper = namespace_mapper
      end

      generator = Typelizer::Generator.new
      generator.call(force: true)

      stale_dir = nested_output_dir.join("Stale/Nested")
      FileUtils.mkdir_p(stale_dir)
      File.write(stale_dir.join("OldType.ts"), "// stale")

      generator.call(force: false)

      expect(stale_dir).not_to exist
      expect(nested_output_dir.join("Stale")).not_to exist
    ensure
      FileUtils.rm_rf(nested_output_dir)
      FileUtils.rm_rf(default_output_dir)
    end
  end

  describe "with output_dir and types_import_path" do
    let(:custom_output_dir) { default_output_dir.parent.join("filename_mapper_import_path") }
    let(:custom_import_path) { "@/types/generated" }

    it "generates nested files that import cross-references via types_import_path" do
      configuration.writer(:nested_imports) do |c|
        c.output_dir = custom_output_dir
        c.types_import_path = custom_import_path
        c.filename_mapper = namespace_mapper
      end

      generator = Typelizer::Generator.new
      generator.call(force: true)

      # Files land in nested directories under output_dir
      post_file = custom_output_dir.join("Alba/Post.ts")
      user_file = custom_output_dir.join("Alba/User.ts")
      expect(post_file).to exist
      expect(user_file).to exist

      # Cross-type imports use types_import_path, not relative paths
      post_content = File.read(post_file)
      expect(post_content).to include("from '#{custom_import_path}'")
      expect(post_content).to include("AlbaUser")

      # index.ts re-exports use nested filename paths
      index_content = File.read(custom_output_dir.join("index.ts"))
      expect(index_content).to include("'./Alba/Post'")
      expect(index_content).to include("'./Alba/User'")
      expect(index_content).to include("as AlbaPost")
      expect(index_content).to include("as AlbaUser")
    ensure
      FileUtils.rm_rf(custom_output_dir)
      FileUtils.rm_rf(default_output_dir)
    end
  end

  describe "per-serializer override" do
    it "allows typelizer_config to override filename_mapper for individual serializers" do
      per_serializer_mapper = ->(serializer) { "Custom/#{serializer.name.demodulize.sub(/Serializer\z/, "")}" }

      context = Typelizer::WriterContext.new
      interface = context.interface_for(Alba::UserSerializer)

      config_with_mapper = interface.config.with_overrides(filename_mapper: per_serializer_mapper)
      allow(interface).to receive(:config).and_return(config_with_mapper)

      expect(interface.filename).to eq("Custom/User")
      expect(interface.name).to eq("AlbaUser")
    end
  end
end
