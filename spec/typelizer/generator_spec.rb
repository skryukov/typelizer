# frozen_string_literal: true

RSpec.describe Typelizer::Generator do
  let(:main_output_dir) { Pathname.new(Typelizer::Config.output_dir) }
  let(:camel_case_output_dir) { main_output_dir.parent.join('camel_case') }

  let(:camel_case_transformer) do
    lambda do |properties|
      properties.map do |prop|
        new_prop = prop.dup
        new_prop.name = new_prop.name.to_s.camelize(:lower)
        new_prop
      end
    end
  end

  before do
    Typelizer.reset_writers
  end

  after do
    FileUtils.rm_rf(main_output_dir)
    FileUtils.rm_rf(camel_case_output_dir)
  end

  context 'with multiple writers configured' do
    subject(:generator) { described_class.new }

    before do
      Typelizer.add_writer do |c|
        c.output_dir = camel_case_output_dir
        c.properties_transformer = camel_case_transformer
      end
    end

    describe '#initialize' do
      it 'creates a base_writer and additional_writers' do
        expect(generator.base_writer).to be_a(Typelizer::Writer)
        expect(generator.additional_writers.size).to eq(1)
        expect(generator.additional_writers.first.config.output_dir).to eq(camel_case_output_dir)
      end
    end

    describe '#call' do
      it 'generates files in multiple formats with correct content' do
        expect { generator.call(force: true) }.not_to raise_error

        expect(main_output_dir).to be_directory
        expect(camel_case_output_dir).to be_directory

        base_post_file = main_output_dir.join('AlbaPost.ts')
        camel_post_file = camel_case_output_dir.join('AlbaPost.ts')

        expect(base_post_file).to exist
        expect(camel_post_file).to exist

        base_content = File.read(base_post_file)
        camel_content = File.read(camel_post_file)

        # Base must contain snake_case format
        expect(base_content).to include('next_post: Post')
        expect(base_content).not_to include('nextPost: Post')

        # Camel must contain camelCase format
        expect(camel_content).to include('nextPost: Post')
        expect(camel_content).not_to include('next_post: Post')
      end
    end
  end
end
