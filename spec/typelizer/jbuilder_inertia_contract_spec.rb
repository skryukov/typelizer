# frozen_string_literal: true

# FROZEN CONTRACT between typelizer's static walker and the jbuilder-inertia
# runtime gem (R5, R6, R7).
#
# The fixture templates under spec/fixtures/jbuilder_inertia_contract/ are
# the shared annotation grammar: jbuilder-inertia's integration suite (U12)
# renders these same template shapes with both gems loaded and asserts that
# runtime semantics match the generated types (a prop typed optional may be
# omitted from the initial Inertia page load; a required prop never is). Do
# not change fixture spellings or assertions here without updating the other
# repo's contract spec in the same change.
#
# Runtime vocabulary source of truth:
# `JbuilderInertia::PropBuilder::KNOWN_DIRECTIVES`
# (defer, optional, merge, once, always, scroll — plus the `deep_merge`
# resolver constructor). Only `defer` and `optional` may omit the key from
# the initial page load, so they are the ONLY widening directives; every
# other directive affects delivery, not presence, and keeps the property
# required. U12 wires the live cross-check against the runtime gem's table
# so upstream vocabulary growth fails loudly instead of going stale here.
RSpec.describe "Jbuilder / jbuilder-inertia contract" do
  describe "static widening (walker side)" do
    let(:views_root) { File.expand_path("../fixtures/jbuilder_inertia_contract", __dir__) }

    before do
      Typelizer::Jbuilder.reset!
      Typelizer::Jbuilder.discover(views_root)
    end

    after { Typelizer::Jbuilder.reset! }

    def render_interface(const_name)
      klass = Typelizer::Jbuilder::Templates.const_get(const_name, false)
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      Typelizer::Renderer.call("interface.ts.erb", interface: ctx.interface_for(klass))
    end

    describe "inertia: kwarg form" do
      let(:output) { render_interface(:ContractKwargForms) }

      it "widens :defer and :optional symbol directives to optional" do
        expect(output).to include("deferred_stats?: unknown")
        expect(output).to include("optional_stats?: unknown")
      end

      it "keeps merge/always/once/scroll required (delivery directives, not omission)" do
        expect(output).to include("merged_list: unknown")
        expect(output).to include("always_value: unknown")
        expect(output).to include("once_value: unknown")
        expect(output).to include("scroll_items: unknown")
        expect(output).not_to include("merged_list?")
        expect(output).not_to include("always_value?")
        expect(output).not_to include("once_value?")
        expect(output).not_to include("scroll_items?")
      end

      it "widens the array form only when it contains a widening directive" do
        expect(output).to include("array_widens?: unknown")
        expect(output).to include("array_keeps: unknown")
        expect(output).not_to include("array_keeps?")
      end

      it "widens the hash form only when a widening directive is a key" do
        expect(output).to include("hash_widens?: unknown")
        expect(output).to include("hash_optional_widens?: unknown")
        expect(output).to include("hash_keeps: unknown")
        expect(output).not_to include("hash_keeps?")
      end
    end

    describe "JbuilderInertia.* resolver-object form" do
      let(:output) { render_interface(:ContractResolverForms) }

      it "widens defer/optional resolvers and infers from the block's final literal expression" do
        expect(output).to include("deferred_amount?: number")
        expect(output).to include("optional_flag?: boolean")
      end

      it "widens defer with constructor options and falls back to unknown for non-literal blocks" do
        expect(output).to include("deferred_grouped?: unknown")
      end

      it "infers Time-pattern block values as string" do
        expect(output).to include("fetched_at?: string")
      end

      it "falls back to name hints when the block value is opaque" do
        expect(output).to include("likes_count?: number")
      end

      it "falls back to bound-model column inference for the prop name" do
        # `typelize_from User` + a `name` column → string, still widened.
        expect(output).to include("name?: string")
      end

      it "keeps merge/deep_merge/once/always/scroll resolvers required while still inferring from blocks" do
        expect(output).to include("merged_tag: string")
        expect(output).to include("deep_merged_meta: unknown")
        expect(output).to include("once_token: string") # ::JbuilderInertia spelling
        expect(output).to include("always_label: string")
        expect(output).to include("scroll_cursor: string")
        expect(output).not_to include("merged_tag?")
        expect(output).not_to include("deep_merged_meta?")
        expect(output).not_to include("once_token?")
        expect(output).not_to include("always_label?")
        expect(output).not_to include("scroll_cursor?")
      end
    end

    describe "typelize: precedence" do
      let(:output) { render_interface(:ContractPrecedence) }

      it "applies the asserted type AND the kwarg widening" do
        expect(output).to include("stats?: Record<string, number>")
      end

      it "applies the asserted type AND the resolver widening" do
        expect(output).to include("metrics?: Record<string, number>")
      end

      it "keeps an asserted prop required under a non-widening directive" do
        expect(output).to include("eager_tags: Array<string>")
        expect(output).not_to include("eager_tags?")
      end
    end

    describe "unknown kwargs" do
      it "never widens for reserved-looking kwargs outside the inertia vocabulary" do
        output = render_interface(:ContractUnknownKwargs)

        expect(output).to include("value: unknown")
        expect(output).not_to include("value?")
      end
    end
  end

  describe "render-time stripping (cross-gem safety)" do
    # The one-way memo and the one-time warning are process-global by design;
    # isolate each example from suite state and restore afterwards.
    around do |example|
      set_ext = Typelizer::Jbuilder::SetExt
      saved_present = set_ext.instance_variable_get(:@foreign_runtime_present)
      saved_warned = set_ext.instance_variable_get(:@foreign_strip_warned)
      set_ext.instance_variable_set(:@foreign_runtime_present, nil)
      set_ext.instance_variable_set(:@foreign_strip_warned, nil)
      example.run
    ensure
      set_ext.instance_variable_set(:@foreign_runtime_present, saved_present)
      set_ext.instance_variable_set(:@foreign_strip_warned, saved_warned)
    end

    def with_capture_logger
      io = StringIO.new
      original = Typelizer.logger
      Typelizer.logger = Logger.new(io)
      yield
      io.string
    ensure
      Typelizer.logger = original
    end

    # Mimics the runtime gem's prepended patch: consumes the kwargs it
    # receives (recording them) so upstream jbuilder never sees a positional
    # options Hash. Matched by SetExt purely via the module NAME.
    def build_fake_inertia_ext(captured)
      Module.new do
        define_method(:set!) do |name, *args, **kwargs, &block|
          captured << kwargs.dup unless kwargs.empty?
          super(name, *args, &block)
        end
      end
    end

    let(:renderer) do
      controller = Class.new(ActionController::Base)
      controller.view_paths = [File.expand_path("../fixtures/jbuilder_views", __dir__)]
      controller.renderer
    end

    context "with no JbuilderInertia loaded" do
      it "strips inertia:, renders clean JSON, and warns exactly once" do
        json = nil
        logs = with_capture_logger do
          json = renderer.render(template: "inertia_kwarg", formats: [:json])
          renderer.render(template: "inertia_kwarg", formats: [:json])
        end

        expect(JSON.parse(json)).to eq("id" => 1, "stats" => {"total" => 2})
        expect(logs).to include("`inertia:` option found but jbuilder-inertia is not installed; option ignored")
        expect(logs.scan("jbuilder-inertia is not installed").size).to eq(1)
      end
    end

    context "with jbuilder-inertia's patch present (typelizer outermost)" do
      it "passes inertia: through untouched and forwards unknown kwargs (no over-stripping)" do
        captured = []
        fake_ext = build_fake_inertia_ext(captured)
        stub_const("JbuilderInertia::JbuilderExt", fake_ext)

        klass = Class.new(::JbuilderTemplate)
        klass.prepend(fake_ext)
        # Typelizer's patch outermost — the prepend order where stripping
        # COULD eat the directive before the runtime gem sees it (R7).
        klass.prepend(Typelizer::Jbuilder::SetExt)

        logs = with_capture_logger do
          template = klass.new(nil)
          template.stats({total: 1}, inertia: :defer)
          template.frob_prop(2, frobnicate: :defer)

          # Inner hash keys stay symbols outside a real render (no JSON round-trip).
          expect(template.attributes!).to eq("stats" => {total: 1}, "frob_prop" => 2)
        end

        expect(captured).to include(hash_including(inertia: :defer))
        expect(captured).to include(hash_including(frobnicate: :defer))
        expect(logs).not_to include("jbuilder-inertia is not installed")
      end
    end

    context "one-way memoization" do
      it "re-checks while absent: a strip-then-prepend sequence picks up the patch on the next render" do
        set_ext = Typelizer::Jbuilder::SetExt
        klass = Class.new(::JbuilderTemplate)
        klass.prepend(set_ext) # outermost — the strip decision lives here

        logs = with_capture_logger do
          before_patch = klass.new(nil)
          before_patch.stats(1, inertia: :defer)
          expect(before_patch.attributes!).to eq("stats" => 1)
        end
        expect(logs).to include("option ignored")
        # The false answer is NOT memoized — it must be recomputed next time.
        expect(set_ext.instance_variable_get(:@foreign_runtime_present)[:inertia]).to be_nil

        captured = []
        fake_ext = build_fake_inertia_ext(captured)
        stub_const("JbuilderInertia::JbuilderExt", fake_ext)
        # Late patch arrival, landing UNDER the already-prepended SetExt.
        klass.include(fake_ext)

        after_patch = klass.new(nil)
        after_patch.stats(2, inertia: :defer)

        expect(captured).to include(hash_including(inertia: :defer))
        expect(after_patch.attributes!).to eq("stats" => 2)
        # ...and once seen, the answer memoizes permanently (one-way).
        expect(set_ext.instance_variable_get(:@foreign_runtime_present)[:inertia]).to be(true)
      end
    end
  end
end
