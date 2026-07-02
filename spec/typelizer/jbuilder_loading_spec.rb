# frozen_string_literal: true

# Load safety and render safety for the jbuilder plugin (R1, R5):
# - requiring "typelizer" must never load prism or jbuilder;
# - an old pre-activated prism must fail loudly with remediation steps;
# - annotated templates must render cleanly even when the plugin is not
#   enabled (render-safety patches are decoupled from enablement).
RSpec.describe "Jbuilder plugin loading" do
  describe "eager require chain" do
    it "requires typelizer without loading prism or jbuilder" do
      lib = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        baseline = $LOADED_FEATURES.grep(/prism/)
        abort "baseline already has prism: \#{baseline}" unless baseline.empty?
        abort "baseline already has Prism" if defined?(Prism)
        abort "baseline already has Jbuilder" if defined?(::Jbuilder)

        require "typelizer"

        leaked = $LOADED_FEATURES.grep(/prism/)
        abort "eager require chain loaded prism: \#{leaked}" unless leaked.empty?
        abort "Prism constant defined after require" if defined?(Prism)
        abort "Jbuilder constant defined after require" if defined?(::Jbuilder)
        puts "CLEAN"
      RUBY

      output = nil
      status = nil
      Bundler.with_unbundled_env do
        output = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: [:child, :out], &:read)
        status = $?
      end

      expect(status).to be_success, "subprocess failed:\n#{output}"
      expect(output).to include("CLEAN")
    end
  end

  describe ".activate_walker!" do
    let(:plugin) { Typelizer::SerializerPlugins::Jbuilder }

    it "memoizes activation and returns the Walker class" do
      expect(plugin.activate_walker!).to be(Typelizer::SerializerPlugins::Jbuilder::Walker)
      expect(plugin.walker_activated?).to be(true)
    end

    it "raises an actionable error naming the active version when prism is too old" do
      plugin.activate_walker! # ensure prism is loaded so VERSION can be stubbed
      previous = plugin.instance_variable_get(:@walker_activated)
      plugin.instance_variable_set(:@walker_activated, nil)
      stub_const("Prism::VERSION", "0.19.0")

      expect { plugin.activate_walker! }.to raise_error(Typelizer::Error) { |error|
        expect(error.message).to include("add prism (>= 1.0) to your Gemfile")
        expect(error.message).to include("prism 0.19.0 is active; the Jbuilder plugin needs >= 1.0")
      }
      expect(plugin.walker_activated?).to be(false)
    ensure
      plugin.instance_variable_set(:@walker_activated, previous)
    end
  end

  describe "render safety (patches decoupled from plugin enablement)" do
    # Referencing ActionView::Base fires the :action_view load hooks — the
    # patches install lazily on action_view load, always before a render is
    # possible. Under random spec order these examples may run before
    # anything else has loaded ActionView, so fire the hooks explicitly.
    before { ActionView::Base }

    let(:renderer) do
      controller = Class.new(ActionController::Base)
      controller.view_paths = [File.expand_path("../fixtures/jbuilder_views", __dir__)]
      controller.renderer
    end

    it "installs the render-safety patches whenever jbuilder is present" do
      # Referencing ActionView::Base fires the :action_view load hooks (the
      # patches install lazily on action_view load — always before a render
      # is possible).
      expect(ActionView::Base.include?(Typelizer::Jbuilder::TemplateHelpers)).to be(true)
      expect(::JbuilderTemplate.ancestors).to include(Typelizer::Jbuilder::SetExt)
    end

    it "is enabled in the dummy app via the jbuilder_views discovery config" do
      expect(Typelizer::Jbuilder.enabled?).to be(true)
    end

    it "renders a typelize-annotated template to clean JSON without activating the walker" do
      expect(Typelizer::SerializerPlugins::Jbuilder).not_to receive(:activate_walker!)

      json = renderer.render(template: "annotated", formats: [:json])

      expect(JSON.parse(json)).to eq("id" => 1, "title" => "Hello", "published" => true)
    end

    it "renders extract!/array!/call with typelize: identical to the unannotated template" do
      annotated = renderer.render(template: "multi_attr_annotated", formats: [:json])
      plain = renderer.render(template: "multi_attr_plain", formats: [:json])

      expect(JSON.parse(annotated)).to eq(JSON.parse(plain))
      expect(JSON.parse(annotated)).to eq(
        "id" => 5, "name" => "Ann", "items" => [{"id" => 1}, {"id" => 2}]
      )
    end

    it "renders json.(...) with annotation-only kwargs and a block as [] instead of crashing" do
      json = renderer.render(template: "call_annotation_only", formats: [:json])

      expect(JSON.parse(json)).to eq([])
    end

    it "renders a plain jbuilder template byte-identical to vanilla jbuilder" do
      expect(::JbuilderTemplate.ancestors).to include(Typelizer::Jbuilder::SetExt)

      rendered = renderer.render(template: "plain", formats: [:json])

      vanilla = ::Jbuilder.encode do |json|
        json.id 2
        json.name "Plain"
        json.tags ["a", "b"]
        json.nested do
          json.flag false
        end
      end

      expect(rendered).to eq(vanilla)
    end
  end

  describe "enablement (gates discovery only)" do
    around do |example|
      config = Typelizer.configuration
      views, enabled = config.jbuilder_views, config.jbuilder_enabled
      example.run
    ensure
      config.jbuilder_views = views
      config.jbuilder_enabled = enabled
    end

    it "auto-enables when jbuilder views are configured" do
      Typelizer.configuration.jbuilder_views = [Rails.root.join("app/views")]
      expect(Typelizer::Jbuilder.enabled?).to be(true)
    end

    it "honors an explicit override in both directions" do
      Typelizer.configuration.jbuilder_views = [Rails.root.join("app/views")]
      Typelizer.configuration.jbuilder_enabled = false
      expect(Typelizer::Jbuilder.enabled?).to be(false)

      Typelizer.configuration.jbuilder_views = nil
      Typelizer.configuration.jbuilder_enabled = true
      expect(Typelizer::Jbuilder.enabled?).to be(true)
    end

    it "round-trips jbuilder_views and jbuilder_enabled through the module-level delegators" do
      Typelizer.jbuilder_views = ["app/views"]
      Typelizer.jbuilder_enabled = false

      expect(Typelizer.jbuilder_views).to eq(["app/views"])
      expect(Typelizer.configuration.jbuilder_views).to eq(["app/views"])
      expect(Typelizer.jbuilder_enabled).to be(false)
      expect(Typelizer.configuration.jbuilder_enabled).to be(false)
    end
  end
end
