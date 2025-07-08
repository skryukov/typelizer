# frozen_string_literal: true

RSpec.describe Typelizer do
  let(:main_config) { described_class::Config }
  let(:main_output_dir) { main_config.output_dir }
  let(:camel_case_output_dir) { main_output_dir.parent.join('camel_case') }
  let(:custom_output_dir) { main_output_dir.parent.join('custom') }

  before do
    described_class.reset_writers
  end

  describe '.add_writer' do
    context 'when configuration is valid' do
      it 'returns a new config instance' do
        config = described_class.add_writer do |c|
          c.output_dir = camel_case_output_dir
        end

        expect(config).to be_a(described_class::Config)
        expect(config.output_dir).to eq(camel_case_output_dir)
      end

      it 'creates an independent copy of the main configuration' do
        config = described_class.add_writer do |c|
          c.output_dir = camel_case_output_dir
          c.type_mapping[:custom] = 'CustomTypeMapping'
          c.types_global << 'SomeGlobalType'
        end

        # Original config must remain unchanged
        expect(main_config.type_mapping.key?(:custom)).to be false
        expect(main_config.types_global).not_to include('SomeGlobalType')

        # New config must have the changes
        expect(config.type_mapping[:custom]).to eq('CustomTypeMapping')
        expect(config.types_global).to include('SomeGlobalType')
      end
    end

    context 'when configuration is invalid' do
      it 'raises an error if output_dir is a duplicate' do
        expect do
          described_class.add_writer do |c|
            c.output_dir = main_output_dir
          end
        end.to raise_error(ArgumentError, /is already used by another writer/)
      end

      it 'raises an error if output_dir is nil' do
        expect do
          described_class.add_writer do |c|
            c.output_dir = nil
          end
        end.to raise_error(ArgumentError, /must be set for additional writer/)
      end
    end
  end

  describe '.reset_writers' do
    it 'clears all additional writers' do
      described_class.add_writer { |c| c.output_dir = camel_case_output_dir }
      expect(described_class.additional_writers.size).to eq(1)

      described_class.reset_writers
      expect(described_class.additional_writers).to be_empty
    end
  end
end
