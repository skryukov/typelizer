# frozen_string_literal: true

RSpec.describe "Typelizer Inheritance", type: :typelizer do
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

  describe "correct config ordering" do
    it "checks Serializer Config ordering over writer configs for conflicting options" do
      # Writer sets options that conflict with Serializer
      configuration.writer(:conflict_writer) do |c|
        c.output_dir = custom_output_dir
        c.null_strategy = :optional
        c.inheritance_strategy = :full
      end

      ctx = Typelizer::WriterContext.new(writer_name: :conflict_writer)

      # CustomTypeUserSerializer contains
      # typelizer_config.inheritance_strategy = :inheritance
      #
      # And other options by inheritance from BaseSerializer
      # typelizer_config.null_strategy = :nullable_and_optional
      cfg = ctx.config_for(Alba::Inherited::CustomTypeUserSerializer)

      # Checking that applied only Serializer configurations
      expect(cfg.null_strategy).to eq(:nullable_and_optional)
      expect(cfg.inheritance_strategy).to eq(:inheritance)
    end
  end
end
