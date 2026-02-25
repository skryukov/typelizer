# frozen_string_literal: true

RSpec.describe Typelizer do
  describe ".interfaces" do
    it "returns an array of Interface objects" do
      interfaces = Typelizer.interfaces
      expect(interfaces).to be_an(Array)
      expect(interfaces).not_to be_empty
      expect(interfaces).to all(be_a(Typelizer::Interface))
    end

    it "does not include empty interfaces" do
      interfaces = Typelizer.interfaces
      interfaces.each do |iface|
        expect(iface).not_to be_empty
      end
    end

    it "accepts a writer_name parameter" do
      interfaces = Typelizer.interfaces(writer_name: :default)
      expect(interfaces).to be_an(Array)
      expect(interfaces).not_to be_empty
    end

    it "filters interfaces when reject_class is set globally" do
      all_interfaces = Typelizer.interfaces
      alba_names = all_interfaces.select { |i| i.serializer.name.start_with?("Alba::") }.map(&:name)
      expect(alba_names).not_to be_empty

      Typelizer.reject_class = ->(serializer:) { serializer.name.start_with?("Alba::") }
      filtered = Typelizer.interfaces
      filtered_names = filtered.map(&:name)

      alba_names.each { |name| expect(filtered_names).not_to include(name) }
    ensure
      Typelizer.reject_class = ->(serializer:) { false }
    end

    it "applies global reject_class to all writer_name values" do
      Typelizer.reject_class = ->(serializer:) { serializer.name.start_with?("Alba::") }

      default_interfaces = Typelizer.interfaces(writer_name: :default)
      default_names = default_interfaces.map { |i| i.serializer.name }

      expect(default_names.none? { |n| n.start_with?("Alba::") }).to be(true)
    ensure
      Typelizer.reject_class = ->(serializer:) { false }
    end

    it "filters openapi_schemas when reject_class is set globally" do
      all_schemas = Typelizer.openapi_schemas
      alba_schema_names = all_schemas.keys.select { |n| n.start_with?("Alba") }
      expect(alba_schema_names).not_to be_empty

      Typelizer.reject_class = ->(serializer:) { serializer.name.start_with?("Alba::") }
      filtered_schemas = Typelizer.openapi_schemas

      alba_schema_names.each { |name| expect(filtered_schemas.keys).not_to include(name) }
    ensure
      Typelizer.reject_class = ->(serializer:) { false }
    end

    it "returns empty array when no serializers are registered" do
      original = Typelizer.base_classes.dup
      Typelizer.send(:base_classes=, Set.new)

      expect(Typelizer.interfaces).to eq([])
    ensure
      Typelizer.send(:base_classes=, original)
    end

    it "uses per-writer reject_class when writer_name is given" do
      configuration = Typelizer.configuration
      default_output_dir = configuration.writer_config(:default).output_dir
      v1_output_dir = Pathname(default_output_dir).parent.join("v1_types")

      configuration.writer(:v1) do |c|
        c.output_dir = v1_output_dir
        c.reject_class = ->(serializer:) { !serializer.name.start_with?("Alba::") }
      end

      v1_interfaces = Typelizer.interfaces(writer_name: :v1)
      v1_serializer_names = v1_interfaces.map { |i| i.serializer.name }

      expect(v1_serializer_names).not_to be_empty
      expect(v1_serializer_names).to all(start_with("Alba::"))

      # Default writer should still include everything
      default_interfaces = Typelizer.interfaces(writer_name: :default)
      default_serializer_names = default_interfaces.map { |i| i.serializer.name }
      non_alba = default_serializer_names.reject { |n| n.start_with?("Alba::") }
      expect(non_alba).not_to be_empty
    ensure
      configuration.reset_writers!
    end

    it "allows two writers with different reject_class to return different subsets" do
      configuration = Typelizer.configuration
      default_output_dir = configuration.writer_config(:default).output_dir

      configuration.writer(:alba_only) do |c|
        c.output_dir = Pathname(default_output_dir).parent.join("alba_only")
        c.reject_class = ->(serializer:) { !serializer.name.start_with?("Alba::") }
      end

      configuration.writer(:ams_only) do |c|
        c.output_dir = Pathname(default_output_dir).parent.join("ams_only")
        c.reject_class = ->(serializer:) { !serializer.name.start_with?("Ams::") }
      end

      alba_names = Typelizer.interfaces(writer_name: :alba_only).map { |i| i.serializer.name }
      ams_names = Typelizer.interfaces(writer_name: :ams_only).map { |i| i.serializer.name }

      expect(alba_names).to all(start_with("Alba::"))
      expect(ams_names).to all(start_with("Ams::"))
      expect(alba_names & ams_names).to be_empty
    ensure
      configuration.reset_writers!
    end
  end

  describe ".openapi_schemas" do
    it "uses per-writer reject_class to scope schemas" do
      configuration = Typelizer.configuration
      default_output_dir = configuration.writer_config(:default).output_dir

      configuration.writer(:v1) do |c|
        c.output_dir = Pathname(default_output_dir).parent.join("v1_schemas")
        c.reject_class = ->(serializer:) { !serializer.name.start_with?("Alba::") }
      end

      v1_schemas = Typelizer.openapi_schemas(writer_name: :v1)
      expect(v1_schemas).not_to be_empty

      # All schema names should correspond to Alba serializers only
      all_schemas = Typelizer.openapi_schemas
      non_alba_schemas = all_schemas.keys.reject { |n| n.start_with?("Alba") }
      expect(non_alba_schemas).not_to be_empty

      non_alba_schemas.each { |name| expect(v1_schemas.keys).not_to include(name) }
    ensure
      configuration.reset_writers!
    end

    it "returns a hash of interface_name => openapi_schema" do
      schemas = Typelizer.openapi_schemas
      expect(schemas).to be_a(Hash)
      expect(schemas).not_to be_empty

      schemas.each do |name, schema|
        expect(name).to be_a(String)
        expect(schema).to be_a(Hash)
        expect(schema[:type]).to eq(:object)
        expect(schema[:properties]).to be_a(Hash)
      end
    end
  end
end

RSpec.describe Typelizer::OpenAPI do
  describe ".schema_for" do
    let(:context) { Typelizer::WriterContext.new }

    it "returns a valid OpenAPI schema for a serializer with AR columns" do
      serializer = Alba::Ar::PostSerializer
      interface = context.interface_for(serializer)
      schema = described_class.schema_for(interface)

      expect(schema[:type]).to eq(:object)
      expect(schema[:properties]).to be_a(Hash)

      # Post has integer :id column, should map to integer not number
      if schema[:properties].key?(:id)
        expect(schema[:properties][:id][:type]).to eq(:integer)
      end

      # Post has datetime :published_at
      if schema[:properties].key?(:published_at)
        expect(schema[:properties][:published_at]).to include(type: :string, format: :"date-time")
      end
    end

    it "includes required fields (non-optional properties)" do
      serializer = Alba::Ar::PostSerializer
      interface = context.interface_for(serializer)
      schema = described_class.schema_for(interface)

      if schema[:required]
        expect(schema[:required]).to be_an(Array)
        schema[:required].each do |req|
          expect(schema[:properties]).to have_key(req)
        end
      end
    end

    it "omits required key when all properties are optional" do
      prop = Typelizer::Property.new(name: :field, type: :string, optional: true)
      interface = instance_double(Typelizer::Interface, properties: [prop])

      schema = described_class.schema_for(interface)
      expect(schema).not_to have_key(:required)
    end
  end

  describe "resolving serializer class references" do
    let(:context) { Typelizer::WriterContext.new }

    # Tests that `typelize field: SomeSerializer` (class constant) and
    # `typelize field: "Module::SomeSerializer"` (class name string)
    # both resolve to Interface objects, producing correct $ref in OpenAPI
    # and correct type names in TypeScript.
    {
      "Alba" => {serializer: Alba::ClassRefSerializer, user_schema: "AlbaUser"},
      "AMS" => {serializer: Ams::ClassRefSerializer, user_schema: "AmsUser"},
      "OjSerializers" => {serializer: OjSerializers::ClassRefSerializer, user_schema: "OjSerializersUser"},
      "Panko" => {serializer: Panko::ClassRefSerializer, user_schema: "PankoUser"}
    }.each do |plugin, config|
      context "with #{plugin}" do
        let(:interface) { context.interface_for(config[:serializer]) }
        let(:schema) { described_class.schema_for(interface) }
        let(:user_schema_name) { config[:user_schema] }

        it "resolves class constant in typelize to Interface" do
          reviewer_prop = interface.properties.find { |p| p.name.to_s == "reviewer" }
          expect(reviewer_prop.type).to be_a(Typelizer::Interface)
        end

        it "resolves class name string in typelize to Interface" do
          editor_prop = interface.properties.find { |p| p.name.to_s == "editor" }
          expect(editor_prop.type).to be_a(Typelizer::Interface)
        end

        it "generates $ref for class constant reference (nullable)" do
          reviewer_schema = schema[:properties]["reviewer"]
          expect(reviewer_schema).to include(:allOf)
          expect(reviewer_schema[:allOf].first).to eq({"$ref" => "#/components/schemas/#{user_schema_name}"})
          expect(reviewer_schema[:nullable]).to eq(true)
        end

        it "generates $ref for class name string reference" do
          editor_schema = schema[:properties]["editor"]
          expect(editor_schema).to eq({"$ref" => "#/components/schemas/#{user_schema_name}"})
        end
      end
    end

    # Tests that `typelize field: "Serializer | null"` extracts nullable and resolves the class
    {
      "Alba" => {serializer: Alba::ClassRefSerializer, user_schema: "AlbaUser", comment_schema: "AlbaComment"},
      "AMS" => {serializer: Ams::ClassRefSerializer, user_schema: "AmsUser", comment_schema: "AmsComment"},
      "OjSerializers" => {serializer: OjSerializers::ClassRefSerializer, user_schema: "OjSerializersUser", comment_schema: "OjSerializersComment"},
      "Panko" => {serializer: Panko::ClassRefSerializer, user_schema: "PankoUser", comment_schema: "PankoComment"}
    }.each do |plugin, config|
      context "#{plugin} nullable union string" do
        let(:interface) { context.interface_for(config[:serializer]) }
        let(:schema) { described_class.schema_for(interface) }

        it "extracts nullable from 'Serializer | null' and resolves class" do
          approver_prop = interface.properties.find { |p| p.name.to_s == "approver" }
          expect(approver_prop.type).to be_a(Typelizer::Interface)
          expect(approver_prop.type.name).to eq(config[:user_schema])
          expect(approver_prop.nullable).to be true
        end

        it "generates nullable $ref for 'Serializer | null' in OpenAPI 3.0" do
          approver_schema = schema[:properties]["approver"]
          expect(approver_schema).to include(:allOf)
          expect(approver_schema[:allOf].first).to eq({"$ref" => "#/components/schemas/#{config[:user_schema]}"})
          expect(approver_schema[:nullable]).to eq(true)
        end

        it "generates anyOf for union of two serializer classes" do
          commentable_schema = schema[:properties]["commentable"]
          expect(commentable_schema).to include(:anyOf)
          expect(commentable_schema[:anyOf]).to contain_exactly(
            {"$ref" => "#/components/schemas/#{config[:user_schema]}"},
            {"$ref" => "#/components/schemas/#{config[:comment_schema]}"}
          )
        end

        it "resolves mixed string and class constant union to Interfaces" do
          mixed_prop = interface.properties.find { |p| p.name.to_s == "mixed_ref" }
          expect(mixed_prop.type).to be_an(Array)
          expect(mixed_prop.type).to all(be_a(Typelizer::Interface))
        end

        it "generates anyOf for mixed string and class constant union" do
          mixed_schema = schema[:properties]["mixed_ref"]
          expect(mixed_schema).to include(:anyOf)
          expect(mixed_schema[:anyOf]).to contain_exactly(
            {"$ref" => "#/components/schemas/#{config[:user_schema]}"},
            {"$ref" => "#/components/schemas/#{config[:comment_schema]}"}
          )
        end
      end
    end

    # Tests that `typelize previous_post: PostSerializer` resolves self-references
    {
      "Alba" => {serializer: Alba::PostSerializer, post_schema: "AlbaPost"},
      "AMS" => {serializer: Ams::PostSerializer, post_schema: "AmsPost"},
      "OjSerializers" => {serializer: OjSerializers::PostSerializer, post_schema: "OjSerializersPost"},
      "Panko" => {serializer: Panko::PostSerializer, post_schema: "PankoPost"}
    }.each do |plugin, config|
      context "#{plugin} self-referencing class constant" do
        it "generates $ref for previous_post" do
          interface = context.interface_for(config[:serializer])
          schema = described_class.schema_for(interface)

          previous_post_schema = schema[:properties]["previous_post"]
          expect(previous_post_schema).to eq({"$ref" => "#/components/schemas/#{config[:post_schema]}"})
        end
      end
    end
  end
end
