# frozen_string_literal: true

# Discovery lifecycle and dev loop (R4, R5 boot half, R2 collision timing):
# - `reset! + discover` runs at the start of every generation cycle, never
#   at boot, so template changes are reflected without a process restart;
# - the parse cache is content-keyed (source digest), the bound model is
#   resolved lazily per generation (Zeitwerk-safe), and every destructive
#   cycle serializes behind the shared GenerationLock.
RSpec.describe "Jbuilder discovery lifecycle" do
  let(:configuration) { Typelizer.configuration }
  let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-discovery") }
  let(:output_dir) { Pathname.new(Dir.mktmpdir("typelizer-jbuilder-discovery-out")) }

  around do |example|
    saved_views = configuration.jbuilder_views
    saved_enabled = configuration.jbuilder_enabled

    # Scoped writer so generation cycles in these specs only write jbuilder
    # template types into a tmpdir.
    configuration.writer(:jb_discovery) do |w|
      w.output_dir = output_dir
      w.reject_class = ->(serializer:) { !serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::") }
    end

    example.run
  ensure
    configuration.jbuilder_views = saved_views
    configuration.jbuilder_enabled = saved_enabled
    configuration.reset_writers!
    CamelCaseWriterFixture.register!(configuration)
    EnumRuntimeWriterFixture.register!(configuration)
    EnumRuntimeVerbatimWriterFixture.register!(configuration)
    Typelizer::Jbuilder.reset!
    FileUtils.rm_rf(views_root)
    FileUtils.rm_rf(output_dir)
    # Full-cycle examples (`Typelizer::Generator.call`) also run the DEFAULT
    # and fixture writers, which write into the dummy app — clean them up so
    # a failing run doesn't leave untracked files under spec/app.
    FileUtils.rm_rf(Typelizer::Config.default_output_dir)
    [CamelCaseWriterFixture, EnumRuntimeWriterFixture, EnumRuntimeVerbatimWriterFixture].each do |fixture|
      FileUtils.rm_rf(fixture.output_dir)
    end
  end

  def write_template(relative_path, body)
    full = File.join(views_root, relative_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
    full
  end

  # One generation cycle scoped to the jb_discovery writer — the same
  # `Typelizer.interfaces` + `Writer#call` sequence `Generator#call` runs
  # per writer (re-discovery happens inside `Typelizer.interfaces`).
  def run_cycle!(force: false)
    interfaces = Typelizer.interfaces(writer_name: :jb_discovery)
    Typelizer::Writer.new(configuration.writer_config(:jb_discovery)).call(interfaces, force: force)
  end

  def render_interface(klass)
    ctx = Typelizer::WriterContext.new(writer_name: nil)
    Typelizer::Renderer.call("interface.ts.erb", interface: ctx.interface_for(klass))
  end

  describe "generation-cycle discovery (dev loop)" do
    it "includes templates added after boot on the next Generator.call, without a restart" do
      configuration.jbuilder_views = [views_root]
      write_template("alpha/show.json.jbuilder", "json.a 1\n")

      Typelizer::Generator.call
      expect(output_dir.join("AlphaShow.ts")).to exist

      write_template("beta/show.json.jbuilder", "json.b 2\n")

      Typelizer::Generator.call
      expect(output_dir.join("BetaShow.ts")).to exist
      expect(output_dir.join("AlphaShow.ts")).to exist
    end

    it "removes the .ts file and the Templates constant when a template is deleted" do
      configuration.jbuilder_views = [views_root]
      write_template("gamma/show.json.jbuilder", "json.g 1\n")
      doomed = write_template("delta/show.json.jbuilder", "json.d 1\n")

      run_cycle!
      expect(output_dir.join("GammaShow.ts")).to exist
      expect(output_dir.join("DeltaShow.ts")).to exist

      File.delete(doomed)
      run_cycle!

      expect(output_dir.join("DeltaShow.ts")).not_to exist
      expect(Typelizer::Jbuilder::Templates.const_defined?(:DeltaShow, false)).to be(false)
      expect(output_dir.join("GammaShow.ts")).to exist
    end

    it "renames types (typelize_as change) without duplicate exports in index.ts" do
      configuration.jbuilder_views = [views_root]
      path = write_template("widgets/show.json.jbuilder", %(typelize_as "WidgetAlpha"\n\njson.w 1\n))

      run_cycle!
      expect(output_dir.join("index.ts").read).to include("WidgetAlpha")

      File.write(path, %(typelize_as "WidgetBeta"\n\njson.w 1\n))
      run_cycle!

      index = output_dir.join("index.ts").read
      expect(index).to include("WidgetBeta")
      expect(index).not_to include("WidgetAlpha")
      exports = index.scan(/default as (\w+)/).flatten
      expect(exports).to eq(exports.uniq)
      expect(output_dir.join("WidgetAlpha.ts")).not_to exist
    end

    it "runs template re-discovery once across a multi-writer Generator.call" do
      configuration.jbuilder_views = [views_root]
      write_template("single/show.json.jbuilder", "json.ok true\n")

      # The pass must span multiple writers for the probe to be meaningful
      # (default writer + the fixture writers + :jb_discovery).
      expect(configuration.writers.size).to be > 1
      allow(Typelizer::Jbuilder).to receive(:discover).and_call_original

      Typelizer::Generator.call

      expect(Typelizer::Jbuilder).to have_received(:discover).once
      expect(output_dir.join("SingleShow.ts")).to exist
    end

    it "regenerates composing parents when a partial gains a field" do
      configuration.jbuilder_views = [views_root]
      partial = write_template("items/_item.json.jbuilder", %(json.id 1\n))
      write_template("items/show.json.jbuilder", %(json.partial! "items/item"\njson.extra true\n))

      run_cycle!
      show = output_dir.join("ItemsShow.ts").read
      expect(show).to include("id: number")
      expect(show).not_to include("label")

      File.write(partial, %(json.id 1\njson.label "x"\n))
      run_cycle!

      expect(output_dir.join("ItemsShow.ts").read).to include("label: string")
    end
  end

  describe "collision timing" do
    it "raises NameCollision at generation time naming both template paths" do
      first = write_template("aaa/thing.json.jbuilder", %(typelize_as "DupName"\n\njson.x 1\n))
      second = write_template("bbb/thing.json.jbuilder", %(typelize_as "DupName"\n\njson.x 1\n))
      configuration.jbuilder_views = [views_root]

      expect { Typelizer.interfaces(writer_name: :jb_discovery) }
        .to raise_error(Typelizer::Jbuilder::NameCollision) { |error|
          expect(error.message).to include(first)
          expect(error.message).to include(second)
        }
    end
  end

  describe "views_root normalization" do
    it "registers correct absolute paths when discover is given a relative root" do
      configuration.jbuilder_views = nil
      write_template("rel/show.json.jbuilder", "json.ok true\n")

      Dir.chdir(File.dirname(views_root)) do
        Typelizer::Jbuilder.discover(File.basename(views_root))
      end

      # The double-prefix bug re-expanded glob results against the relative
      # root, deriving garbage names from the duplicated path — the constant
      # below only exists when the path was normalized exactly once.
      expect(Typelizer::Jbuilder::Templates.const_defined?(:RelShow, false)).to be(true)
      registered = Typelizer::Jbuilder::Templates::RelShow._template_path
      expect(Pathname.new(registered)).to be_absolute
      expect(File.identical?(registered, File.join(views_root, "rel/show.json.jbuilder"))).to be(true)
    end

    it "accepts a Pathname views_root" do
      configuration.jbuilder_views = nil
      write_template("pn/show.json.jbuilder", "json.ok true\n")

      Typelizer::Jbuilder.discover(Pathname.new(views_root))

      expect(Typelizer::Jbuilder::Templates.const_defined?(:PnShow, false)).to be(true)
      expect(Typelizer::Jbuilder::Templates::PnShow._template_path)
        .to eq(File.expand_path(File.join(views_root, "pn/show.json.jbuilder")))
    end
  end

  describe "type-name sanitization and validation" do
    it "derives deterministic valid names for digit-leading and dotted path segments" do
      configuration.jbuilder_views = nil
      write_template("2fa/show.json.jbuilder", "json.ok true\n")
      write_template("v2.1/status.json.jbuilder", "json.ok true\n")

      Typelizer::Jbuilder.discover(views_root)

      expect(Typelizer::Jbuilder::Templates.const_defined?(:N2faShow, false)).to be(true)
      expect(Typelizer::Jbuilder::Templates.const_defined?(:V21Status, false)).to be(true)
    end

    it "raises a Typelizer::Error naming the template and a typelize_as hint for an invalid explicit name" do
      configuration.jbuilder_views = nil
      path = write_template("users/list.json.jbuilder", %(typelize_as "userList"\n\njson.ok true\n))

      expect { Typelizer::Jbuilder.discover(views_root) }
        .to raise_error(Typelizer::Error) { |error|
          expect(error.message).to include(path)
          expect(error.message).to include("userList")
          expect(error.message).to include("typelize_as")
        }
    end
  end

  describe "content-keyed parse cache" do
    it "re-parses a template whose content changed without an explicit cache reset" do
      path = write_template("cache/show.json.jbuilder", %(typelize_as "CacheOne"\n\njson.x 1\n))
      walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!

      expect(walker.metadata_for(path)[:type_name]).to eq("CacheOne")

      File.write(path, %(typelize_as "CacheTwo"\n\njson.x 1\n))

      expect(walker.metadata_for(path)[:type_name]).to eq("CacheTwo")
    end
  end

  describe "lazy model resolution (Zeitwerk-safe)" do
    it "constantizes typelize_from per generation so a reloaded class's columns are picked up" do
      write_template("late/show.json.jbuilder", <<~RUBY)
        typelize_from LateBoundModel

        json.extract! record, :id, :name, :title
      RUBY

      # Explicit discover (no jbuilder_views): registration happens exactly
      # once, so fresh columns can only come from per-generation resolution.
      configuration.jbuilder_views = nil
      stub_const("LateBoundModel", Class.new(ApplicationRecord) { self.table_name = "users" })
      Typelizer::Jbuilder.discover(views_root)
      klass = Typelizer::Jbuilder::Templates::LateShow

      output = render_interface(klass)
      expect(output).to include("name: string")
      expect(output).to include("title: unknown")

      # Simulate a Zeitwerk reload: same constant name, brand-new class object.
      stub_const("LateBoundModel", Class.new(ApplicationRecord) { self.table_name = "posts" })

      output = render_interface(klass)
      expect(output).to include("title: string | null")
      expect(output).to include("name: unknown")
    end
  end

  describe "explicit discover (non-Rails flow)" do
    it "leaves explicit registrations untouched across generation cycles when jbuilder_views is unset" do
      configuration.jbuilder_views = nil
      configuration.jbuilder_enabled = nil
      write_template("manual/show.json.jbuilder", "json.ok true\n")

      Typelizer::Jbuilder.discover(views_root)
      expect(Typelizer::Jbuilder::Templates.const_defined?(:ManualShow, false)).to be(true)

      interfaces = Typelizer.interfaces
      expect(interfaces.map(&:name)).to include("ManualShow")
      expect(Typelizer::Jbuilder::Templates.const_defined?(:ManualShow, false)).to be(true)
    end
  end

  describe "reset! scope" do
    it "prunes only jbuilder-registered base_classes and per-discovery state" do
      sentinel = "SomeUserSerializerSentinel"
      configuration.jbuilder_views = [views_root]
      write_template("scoped/show.json.jbuilder", "json.ok true\n")
      Typelizer::Jbuilder.discover(views_root)

      Typelizer.base_classes << sentinel
      non_jbuilder = Typelizer.base_classes.reject { |n| n.start_with?("Typelizer::Jbuilder::Templates::") }

      expect(Typelizer.base_classes).to include("Typelizer::Jbuilder::Templates::ScopedShow")

      Typelizer::Jbuilder.reset!

      expect(Typelizer.base_classes.grep(/\ATypelizer::Jbuilder::Templates::/)).to be_empty
      expect(Typelizer.base_classes.to_a).to include(*non_jbuilder)
      # Cross-cycle state survives: walker activation and discovery config.
      expect(Typelizer::SerializerPlugins::Jbuilder.walker_activated?).to be(true)
      expect(configuration.jbuilder_views).to eq([views_root])
    ensure
      Typelizer.base_classes.delete(sentinel)
    end
  end

  describe "generation lock" do
    it "serializes a racing refresh! against a real generation cycle so constants are never yanked mid-cycle" do
      configuration.jbuilder_views = [views_root]
      write_template("race/show.json.jbuilder", "json.ok true\n")

      events = Queue.new
      entered = Queue.new

      # Instrument a point INSIDE the real lock path (`Typelizer.interfaces`
      # calls `load_serializers` after `Jbuilder.refresh!`, with the
      # GenerationLock held) to probe constant stability mid-cycle while a
      # destructive `refresh!` contends for the same lock.
      allow(Typelizer).to receive(:load_serializers).and_wrap_original do |original|
        klass = Typelizer::Jbuilder::Templates.const_get(:RaceShow, false)
        entered << true
        sleep 0.05 # widen the race window; correctness doesn't depend on it
        # Still the same constant mid-cycle — the racing refresh! had to wait.
        events << [:mid_cycle_stable, klass.equal?(Typelizer::Jbuilder::Templates.const_get(:RaceShow, false))]
        original.call
      end

      generation = Thread.new do
        names = Typelizer.interfaces(writer_name: :jb_discovery).map(&:name)
        events << [:generation_done, names]
      end

      racer = Thread.new do
        entered.pop # deterministic: contend only once the cycle holds the lock
        Typelizer::Jbuilder.refresh!
        events << [:refresh_done]
      end

      [generation, racer].each(&:join)

      expect(events.pop).to eq([:mid_cycle_stable, true])
      # The lock is released before either thread reports completion, so the
      # last two events can land in either order — assert content, not order.
      remaining = [events.pop, events.pop]
      expect(remaining).to include([:refresh_done])
      generation_done = remaining.find { |event| event.first == :generation_done }
      expect(generation_done&.last).to include("RaceShow")
    end
  end

  describe "production boot" do
    it "performs no template discovery or walker activation at boot" do
      script = <<~RUBY
        require File.expand_path("../app/config/environment", #{File.expand_path(__dir__).inspect})

        abort "walker activated at boot" if Typelizer::SerializerPlugins::Jbuilder.walker_activated?
        consts = Typelizer::Jbuilder::Templates.constants
        abort "templates discovered at boot: \#{consts.inspect}" unless consts.empty?
        abort "registry populated at boot" unless Typelizer::Jbuilder.registry.empty?
        abort "jbuilder_views discovery config missing" unless Typelizer::Jbuilder.enabled?
        puts "NO_BOOT_DISCOVERY"
      RUBY

      env = {"RAILS_ENV" => "production", "TYPELIZER" => nil, "SECRET_KEY_BASE" => "dummy-secret"}
      output = IO.popen(env, [RbConfig.ruby, "-e", script], err: [:child, :out], &:read)
      status = $?

      expect(status).to be_success, "production boot failed:\n#{output}"
      expect(output).to include("NO_BOOT_DISCOVERY")
    end
  end
end
