# frozen_string_literal: true

# Runtime conformance mode: every response a suite renders becomes a
# differential check of the generated types against real data. The generic
# core (Typelizer::Conformance) validates any parsed JSON against any
# Interface; the jbuilder recorder maps ActionView render notifications to
# registered templates automatically.
RSpec.describe "runtime conformance" do
  let(:views_root) { Dir.mktmpdir("typelizer-conformance") }

  before { Typelizer::Jbuilder.reset! }

  after do
    Typelizer::Jbuilder::Conformance.unsubscribe!
    Typelizer::Jbuilder.reset!
    FileUtils.rm_rf(views_root)
  end

  def write_template(relative_path, body)
    full = File.join(views_root, relative_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
    full
  end

  def interface_for(klass)
    Typelizer::WriterContext.new(writer_name: nil).interface_for(klass)
  end

  describe Typelizer::Conformance do
    let(:iface) do
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.id 1
        json.title "x", typelize: "string | null"
        json.badge do
          json.label "pro"
        end
        json.tags @tags do |tag|
          json.name tag[:name], typelize: "string"
        end
        json.draft true if @draft
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      interface_for(Typelizer::Jbuilder::Templates::PostsShow)
    end

    it "accepts a conforming document (optional absent, nullable null, arrays, shapes)" do
      doc = {"id" => 2, "title" => nil, "badge" => {"label" => "x"}, "tags" => [{"name" => "a"}]}
      expect(described_class.check(iface, doc)).to be_empty
    end

    it "rejects a wrong scalar, a missing required key, and an uncovered key" do
      doc = {"id" => "not-a-number", "title" => "t", "badge" => {"label" => "x"}, "surprise" => 1}
      kinds = described_class.check(iface, doc).map(&:kind)
      expect(kinds).to contain_exactly(:type_mismatch, :missing_required_key, :uncovered_key)
    end

    it "rejects null under a nullable:false property" do
      doc = {"id" => 1, "title" => "t", "badge" => nil, "tags" => []}
      violations = described_class.check(iface, doc)
      expect(violations.map(&:kind)).to include(:null_rejected)
      expect(violations.first.path).to eq("$.badge")
    end

    it "checks array elements against the element shape" do
      doc = {"id" => 1, "title" => "t", "badge" => {"label" => "x"}, "tags" => [{"name" => 5}]}
      violations = described_class.check(iface, doc)
      expect(violations.map(&:path)).to include("$.tags[0].name")
    end

    it "validates composed-partial intersections with union coverage" do
      write_template("shared/_info.json.jbuilder", <<~RUBY)
        json.total total, typelize: "number"
      RUBY
      write_template("courses/show.json.jbuilder", <<~RUBY)
        json.course do
          json.partial! "shared/info", total: 1
          json.is_active true
        end
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      composed = interface_for(Typelizer::Jbuilder::Templates::CoursesShow)

      ok = {"course" => {"total" => 3, "is_active" => true}}
      expect(described_class.check(composed, ok)).to be_empty

      bad = {"course" => {"total" => "three", "is_active" => true}}
      expect(described_class.check(composed, bad).map(&:kind)).to eq([:type_mismatch])
    end

    it "validates root arrays element-wise" do
      write_template("items/index.json.jbuilder", <<~RUBY)
        json.array! @items do |item|
          json.total item[:total]
        end
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      root = interface_for(Typelizer::Jbuilder::Templates::ItemsIndex)

      expect(described_class.check(root, [{"total" => 1}])).to be_empty
      expect(described_class.check(root, {"total" => 1}).map(&:kind)).to eq([:type_mismatch])
      expect(described_class.check(root, [{"total" => "x"}]).map(&:path)).to eq(["$[0].total"])
    end

    it "check! raises Mismatch with a formatted per-violation report" do
      expect {
        described_class.check!(iface, {"id" => "nope"}, source: "posts/show.json.jbuilder")
      }.to raise_error(Typelizer::Conformance::Mismatch) { |error|
        expect(error.message).to include("posts/show.json.jbuilder")
        expect(error.message).to include("[type_mismatch] at $.id")
        expect(error.violations).not_to be_empty
      }
    end

    it "works for non-jbuilder serializer interfaces too" do
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      alba_iface = ctx.interface_for(Alba::UserSerializer)
      props = alba_iface.properties.to_h { |p| [p.name.to_s, p] }
      doc = props.transform_values { |_| nil } # every key null: flushes out nullability
      violations = described_class.check(alba_iface, doc)
      # No assertion on exact content — just that the generic core walks a
      # non-jbuilder interface without touching jbuilder-specific machinery.
      expect(violations).to all(be_a(Typelizer::Conformance::Violation))
    end
  end

  describe Typelizer::Jbuilder::Conformance do
    # A real ActionView render through controller.renderer — the identifier
    # in the render notification is what maps back to the registered template.
    let(:renderer) do
      controller = Class.new(ActionController::Base)
      controller.view_paths = [views_root]
      controller.renderer
    end

    it "validates a conforming response end-to-end from the render notification" do
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.id 1
        json.name @name
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      described_class.subscribe!

      body = renderer.render(template: "posts/show", formats: [:json], assigns: {name: "Ann"})

      expect(described_class.last_template_path).to end_with("posts/show.json.jbuilder")
      expect(described_class.validate_last_render!(body, views_root: views_root)).to be(true)
    end

    it "raises Mismatch when the emitted type lies about the render" do
      # The annotation promises number; the render produces a string.
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.total "not-a-number", typelize: "number"
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      described_class.subscribe!

      body = renderer.render(template: "posts/show", formats: [:json])

      expect {
        described_class.validate_last_render!(body, views_root: views_root)
      }.to raise_error(Typelizer::Conformance::Mismatch) { |error|
        expect(error.violations.map(&:path)).to eq(["$.total"])
      }
    end

    it "collects violations without raising via the non-bang variant" do
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.total "s", typelize: "number"
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      described_class.subscribe!

      body = renderer.render(template: "posts/show", formats: [:json])
      violations = described_class.validate_last_render(body, views_root: views_root)

      expect(violations.map(&:kind)).to eq([:type_mismatch])
    end

    it "explains when no jbuilder template was rendered" do
      described_class.subscribe!
      expect {
        described_class.validate_last_render!("{}")
      }.to raise_error(Typelizer::Error, /no jbuilder template was rendered/)
    end
  end
end
