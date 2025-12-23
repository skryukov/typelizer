# frozen_string_literal: true

RSpec.describe Typelizer::Interface, type: :typelizer do
  describe "#imports" do
    context "with self-referential associations in namespaced serializers" do
      # Simulate a namespaced serializer with a self-referencing association
      # like a tree structure (parent/children of the same type)
      let(:tree_serializer) do
        Class.new do
          include Alba::Resource
          include Typelizer::DSL

          def self.name
            "Inventory::TreeNodeSerializer"
          end

          attributes :id, :name
          has_one :parent, resource: self
          has_many :children, resource: self
        end
      end

      it "does not import itself" do
        ctx = Typelizer::WriterContext.new(writer_name: :default)
        interface = described_class.new(serializer: tree_serializer, context: ctx)

        # The type name will be "InventoryTreeNode" (namespace segments joined)
        expect(interface.name).to eq("InventoryTreeNode")

        # Self-references should not appear in imports
        expect(interface.imports).not_to include("InventoryTreeNode")
      end
    end
  end
end
