# frozen_string_literal: true

RSpec.describe Typelizer::Configuration, type: :typelizer do
  subject(:config_manager) { configuration }

  let(:configuration) { Typelizer.configuration }
  let(:default_output_dir) { configuration.writer_config(:default).output_dir }
  let(:custom_output_dir) { Pathname(default_output_dir).parent.join("custom") }

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

  describe "#writer" do
    it "creates and stores a new writer config" do
      config_manager.writer(:custom) do |c|
        c.output_dir = custom_output_dir
        c.comments = true
      end

      expect(config_manager.writers).to have_key(:custom)

      custom = config_manager.writer_config(:custom)
      expect(custom).to be_a(Typelizer::Config)
      expect(custom.output_dir).to eq(custom_output_dir)
      expect(custom.comments).to be(true)
      expect(custom).to be_frozen
    end

    it "does not affect changes in default writer to others" do
      configuration.comments = false

      config_manager.writer(:default) do |c|
        c.comments = true
      end

      config_manager.writer(:custom) do |c|
        c.output_dir = custom_output_dir
      end

      custom = config_manager.writer_config(:custom)
      default = config_manager.writer_config(:default)

      expect(custom.comments).to be(false)
      expect(default.comments).to be(true)
    end

    it "rejects blank writer names" do
      expect { configuration.writer("") }.to raise_error(ArgumentError, /Writer name cannot be empty/)
    end

    it "requires output_dir for non-default writers" do
      expect do
        configuration.writer(:no_dir) { |c|
          c.comments = true
          c.output_dir = nil
        }
      end.to raise_error(ArgumentError, /output_dir must be configured for writer :no_dir/)
    end

    it "does not mirror writer(:default) block changes into global_settings" do
      before_global = configuration.global_settings.dup
      configuration.writer(:default) { |c| c.prefer_double_quotes = true }

      expect(configuration.global_settings).to eq(before_global)
    end

    it "raises an error when two writers use the same output_dir" do
      config_manager.writer(:one) { |c| c.output_dir = custom_output_dir }
      expect do
        config_manager.writer(:two) { |c| c.output_dir = custom_output_dir }
      end.to raise_error(ArgumentError, /already in use by writer :one/)
    end

    it "allows reusing an output_dir after reset_writers!" do
      config_manager.writer(:one) { |c| c.output_dir = custom_output_dir }
      configuration.reset_writers!
      expect { config_manager.writer(:two) { |c| c.output_dir = custom_output_dir } }.not_to raise_error
    end
  end

  describe "writer inheritance via :from" do
    it "clones settings from an existing writer when :from is provided" do
      # Tweak :default but DO NOT mirror into globals
      configuration.writer(:default) { |w| w.prefer_double_quotes = true }

      # Create a new writer explicitly cloning :default
      configuration.writer(:derived, from: :default) do |w|
        w.output_dir = custom_output_dir
      end

      derived = configuration.writer_config(:derived)
      default = configuration.writer_config(:default)

      expect(derived.prefer_double_quotes).to be(true) # cloned from :default
      expect(derived.output_dir).to eq(custom_output_dir)
      expect(default.prefer_double_quotes).to be(true)
    end

    it "falls back to global flat settings when :from references a non-existent writer" do
      # Set a global flat setting (affects all future writers)
      configuration.comments = true

      configuration.writer(:ghost_clone, from: :i_do_not_exist) do |w|
        w.output_dir = custom_output_dir
      end

      ghost = configuration.writer_config(:ghost_clone)
      expect(ghost.comments).to be(true) # inherited from global settings, not from writer(:default)
    end

    it "does not retroactively change an already created writer if the source writer changes later" do
      # Base writer
      configuration.writer(:base) do |w|
        w.output_dir = custom_output_dir
        w.prefer_double_quotes = true
      end

      # Clone from :base at this moment in time
      other_dir = Pathname(custom_output_dir).parent.join("another")
      configuration.writer(:clone, from: :base) do |w|
        w.output_dir = other_dir
      end

      # Now mutate :base clone must remain as it was at creation time
      configuration.writer(:base) do |w|
        w.prefer_double_quotes = false
      end

      clone = configuration.writer_config(:clone)
      base = configuration.writer_config(:base)

      expect(clone.prefer_double_quotes).to be(true)
      expect(base.prefer_double_quotes).to be(false)
    end
  end

  describe "flat setters on the configuration root" do
    it "update the default writer and global_settings consistently" do
      configuration.types_import_path = "@/my_types"
      configuration.prefer_double_quotes = true

      default_cfg = configuration.writer_config(:default)
      expect(default_cfg.types_import_path).to eq("@/my_types")
      expect(default_cfg.prefer_double_quotes).to be(true)

      expect(configuration.global_settings[:types_import_path]).to eq("@/my_types")
      expect(configuration.global_settings[:prefer_double_quotes]).to be(true)
    end

    it "rejects blank or nil output_dir" do
      expect { configuration.output_dir = "" }.to raise_error(ArgumentError, /must be configured for writer :default/)
      expect { configuration.output_dir = nil }.to raise_error(ArgumentError, /must be configured for writer :default/)
    end
  end

  describe "flat getters on the configuration root" do
    it "allows read-modify-write for hash attributes like type_mapping" do
      # get current mapping via flat getter, then merge and assign back
      current = configuration.type_mapping
      expect(current).to be_a(Hash)

      configuration.type_mapping = current.merge(float: :number, jsonb: :object)

      updated = configuration.writer_config(:default).type_mapping
      expect(updated[:float]).to eq(:number)
      expect(updated[:jsonb]).to eq(:object)
    end
  end

  describe "#writer_config" do
    it "returns the default writer config when no name is given" do
      expect(config_manager.writer_config).to eq(config_manager.writers[:default])
    end

    it "returns the requested named writer config when present" do
      config_manager.writer(:another) { |c| c.output_dir = custom_output_dir }
      expect(config_manager.writer_config(:another).output_dir).to eq(custom_output_dir)
    end
  end
end
