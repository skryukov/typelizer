# frozen_string_literal: true

# `inference_locked` marks a property whose type was read off a source-code
# literal (e.g. jbuilder's `json.category 42`). Model column METADATA
# (comments/enums) describes the column's value, not the literal one, so the
# metadata pass must skip locked properties — both at the interface level
# (Interface#infer_types) and inside nested Shape types
# (TypeInference#infer_shape_types).
RSpec.describe "inference_locked metadata guards" do
  let(:context) { Typelizer::WriterContext.new(writer_name: nil) }

  # Alba::PostSerializer maps to the Post model, whose `category` column
  # carries enum metadata (news/article/blog) via `enum category:`.
  def interface_with_properties(props)
    interface = Typelizer::Interface.new(serializer: Alba::PostSerializer, context: context)
    plugin = Object.new
    plugin.define_singleton_method(:properties) { props }
    plugin.define_singleton_method(:root_key) { nil }
    plugin.define_singleton_method(:meta_fields) { nil }
    allow(interface).to receive(:serializer_plugin).and_return(plugin)
    interface
  end

  describe "interface-level properties (Interface#infer_types)" do
    it "does not copy model enum metadata onto an inference_locked property" do
      locked = Typelizer::Property.new(
        name: "category", column_name: "category", type: :number, inference_locked: true
      )
      result = interface_with_properties([locked]).properties.first

      expect(result.type).to eq(:number)
      expect(result.enum).to be_nil
      expect(result.enum_type_name).to be_nil
    end

    it "still applies model enum metadata to an unlocked property (control)" do
      plain = Typelizer::Property.new(name: "category", column_name: "category", type: nil)
      result = interface_with_properties([plain]).properties.first

      expect(result.enum).to eq(%w[news article blog])
      expect(result.enum_type_name).to eq("PostCategory")
    end
  end

  describe "Shape-nested properties (TypeInference#infer_shape_types)" do
    def shape_property(sub_property)
      Typelizer::Property.new(
        name: "meta", column_name: "meta",
        type: Typelizer::Shape.new(properties: [sub_property])
      )
    end

    it "does not copy model enum metadata onto an inference_locked nested property" do
      locked = Typelizer::Property.new(
        name: "category", column_name: "category", type: :number, inference_locked: true
      )
      result = interface_with_properties([shape_property(locked)]).properties.first
      nested = result.type.properties.first

      expect(nested.type).to eq(:number)
      expect(nested.enum).to be_nil
      expect(nested.enum_type_name).to be_nil
    end

    it "still applies model enum metadata to an unlocked typed nested property (control)" do
      plain = Typelizer::Property.new(name: "category", column_name: "category", type: :number)
      result = interface_with_properties([shape_property(plain)]).properties.first
      nested = result.type.properties.first

      expect(nested.enum).to eq(%w[news article blog])
      expect(nested.enum_type_name).to eq("PostCategory")
    end
  end
end
