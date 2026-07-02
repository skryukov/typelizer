# frozen_string_literal: true

# Interface#self_type_name derives the name a serializer uses to reference
# ITSELF in typelize declarations (so it can be excluded from imports). It is
# the demodulized serializer_name_mapper output — the SAME name the interface
# exports — so it follows the mapper's suffix policy: the default mapper
# strips only a TRAILING Serializer/Resource (a leftmost scan would extract
# "A" from `AResourceFoo::UserSerializer` — "A" followed by "Resource…"),
# while a non-stripping mapper (jbuilder's demodulize) keeps the suffix, so a
# genuinely-different sibling name is not misidentified as self. Names with
# no suffix at all (jbuilder's `Templates::Post` constants) must not crash.
RSpec.describe Typelizer::Interface, "#self_type_name" do
  let(:context) { Typelizer::WriterContext.new(writer_name: nil) }

  def self_type_name_for(class_name)
    stub_const(class_name, Class.new)
    interface = described_class.new(serializer: Object.const_get(class_name), context: context)
    interface.send(:self_type_name)
  end

  it "strips the Serializer suffix from a namespaced serializer" do
    expect(self_type_name_for("Foo::UserSerializer")).to eq("User")
  end

  it "strips the Resource suffix" do
    expect(self_type_name_for("UserResource")).to eq("User")
  end

  it "is not confused by Serializer/Resource appearing mid-namespace" do
    expect(self_type_name_for("AResourceFoo::UserSerializer")).to eq("User")
  end

  it "keeps the demodulized name when there is no suffix to strip" do
    expect(self_type_name_for("Templates::Post")).to eq("Post")
  end

  it "follows a custom serializer_name_mapper that does not strip suffixes" do
    stub_const("Templates::Post2Resource", Class.new)
    interface = described_class.new(serializer: Templates::Post2Resource, context: context)
    allow(interface).to receive(:config).and_return(
      instance_double(Typelizer::Config, serializer_name_mapper: ->(s) { s.name.split("::").last })
    )

    expect(interface.send(:self_type_name)).to eq("Post2Resource")
  end

  # jbuilder's mapper is `->(s) { s.name.demodulize }` — no suffix stripping.
  # A template `typelize_as "Post2Resource"` embedding a partial
  # `typelize_as "Post2"` exports Post2Resource and references Post2: the
  # hardcoded-strip version subtracted "Post2" as "self" and emitted
  # `featured: Post2;` with no import (TS2304).
  describe "with jbuilder templates (non-stripping mapper)" do
    let(:views_root) { Dir.mktmpdir("typelizer-self-type-name") }

    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(views_root)
    end

    def write_template(relative_path, body)
      full = File.join(views_root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end

    it "imports a partial interface whose name is the host's name minus a Resource suffix" do
      write_template("posts2/_post2.json.jbuilder", <<~RUBY)
        typelize_as "Post2"
        json.id 2
        json.title "t", typelize: "string"
      RUBY
      write_template("posts2/featured.json.jbuilder", <<~RUBY)
        typelize_as "Post2Resource"
        json.featured do
          json.partial! "posts2/post2"
        end
      RUBY
      Typelizer::Jbuilder.discover(views_root)

      interface = context.interface_for(Typelizer::Jbuilder::Templates::Post2Resource)
      output = Typelizer::Renderer.call("interface.ts.erb", interface: interface)

      expect(interface.send(:self_type_name)).to eq("Post2Resource")
      expect(interface.imports).to eq(["Post2"])
      expect(output).to include("import type {Post2} from '@/types'")
    end

    it "still excludes a genuine self-reference from imports" do
      write_template("chapters/_chapter.json.jbuilder", <<~RUBY)
        typelize_as "Chapter"
        json.title "t", typelize: "string"
        json.next nil, typelize: "Chapter | null"
      RUBY
      Typelizer::Jbuilder.discover(views_root)

      interface = context.interface_for(Typelizer::Jbuilder::Templates::Chapter)

      expect(interface.imports).to be_empty
    end
  end
end
