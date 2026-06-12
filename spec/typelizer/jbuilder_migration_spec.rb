# frozen_string_literal: true

# Staged Alba→jbuilder migration ergonomics (R13):
# - jbuilder templates emit through a dedicated writer (`writer(:name)` with
#   its own `output_dir`), so a migrating app keeps the generated jbuilder
#   types isolated from the legacy serializer types;
# - per-writer stale-file cleanup never deletes another writer's files, even
#   when one writer's output_dir is nested inside another's;
# - duplicate exported type names across plugins sharing ONE index (Alba
#   `Alba::PostSerializer` → `AlbaPost` and a `typelize_as "AlbaPost"`
#   template) warn at generation time naming both sources.
RSpec.describe "Jbuilder migration ergonomics" do
  let(:configuration) { Typelizer.configuration }
  let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-migration-views") }
  let(:scratch_dir) { Pathname.new(Dir.mktmpdir("typelizer-jbuilder-migration-out")) }

  around do |example|
    saved_views = configuration.jbuilder_views
    saved_enabled = configuration.jbuilder_enabled
    configuration.jbuilder_views = [views_root]

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
    FileUtils.rm_rf(scratch_dir)
  end

  def write_template(relative_path, body)
    full = File.join(views_root, relative_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
    full
  end

  # Mirrors how a migrating app isolates legacy serializer output: a writer
  # scoped to one Alba serializer via `reject_class`.
  def register_alba_writer!(output_dir)
    configuration.writer(:mig_alba) do |w|
      w.output_dir = output_dir
      w.reject_class = ->(serializer:) { serializer.name != "Alba::PostSerializer" }
    end
  end

  # The recommended jbuilder-side config: a dedicated writer that keeps only
  # template-derived classes.
  def register_jbuilder_writer!(output_dir)
    configuration.writer(:mig_jbuilder) do |w|
      w.output_dir = output_dir
      w.reject_class = ->(serializer:) { !serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::") }
    end
  end

  # One non-force generation cycle for a single writer — the same
  # `Typelizer.interfaces` + `Writer#call` sequence `Generator#call` runs,
  # exercising the `cleanup_stale_files` path.
  def run_writer!(name)
    interfaces = Typelizer.interfaces(writer_name: name)
    Typelizer::Writer.new(configuration.writer_config(name)).call(interfaces, force: false)
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

  describe "cross-writer cleanup safety" do
    it "removes only same-writer stale files when writers use sibling output dirs" do
      alba_out = scratch_dir.join("alba_types")
      jbuilder_out = scratch_dir.join("jbuilder_types")
      register_alba_writer!(alba_out)
      register_jbuilder_writer!(jbuilder_out)
      write_template("posts/show.json.jbuilder", "json.ok true\n")

      run_writer!(:mig_alba)
      run_writer!(:mig_jbuilder)
      expect(alba_out.join("AlbaPost.ts")).to exist
      expect(jbuilder_out.join("PostsShow.ts")).to exist

      stale_alba = alba_out.join("StaleAlba.ts").tap { |f| f.write("// stale\n") }
      stale_jbuilder = jbuilder_out.join("StaleJbuilder.ts").tap { |f| f.write("// stale\n") }

      run_writer!(:mig_alba)
      expect(stale_alba).not_to exist
      expect(stale_jbuilder).to exist
      expect(jbuilder_out.join("PostsShow.ts")).to exist

      run_writer!(:mig_jbuilder)
      expect(stale_jbuilder).not_to exist
      expect(alba_out.join("AlbaPost.ts")).to exist
    end

    it "never collects a nested writer's files as stale (jbuilder dir inside the legacy types dir)" do
      alba_out = scratch_dir.join("types")
      jbuilder_out = scratch_dir.join("types", "jbuilder")
      register_alba_writer!(alba_out)
      register_jbuilder_writer!(jbuilder_out)
      write_template("posts/show.json.jbuilder", "json.ok true\n")

      run_writer!(:mig_jbuilder)
      run_writer!(:mig_alba)

      # The nested writer's output sits inside the outer writer's stale-scan
      # glob — it must be excluded, not deleted.
      expect(jbuilder_out.join("PostsShow.ts")).to exist
      expect(jbuilder_out.join("index.ts")).to exist
      expect(alba_out.join("AlbaPost.ts")).to exist

      stale_jbuilder = jbuilder_out.join("StaleJbuilder.ts").tap { |f| f.write("// stale\n") }

      run_writer!(:mig_alba)
      expect(stale_jbuilder).to exist
      expect(jbuilder_out.join("PostsShow.ts")).to exist

      run_writer!(:mig_jbuilder)
      expect(stale_jbuilder).not_to exist
      expect(alba_out.join("AlbaPost.ts")).to exist
      expect(alba_out.join("index.ts")).to exist
    end

    it "protects a serializer-level output_dir override pointing into another writer's dir from that writer's cleanup" do
      jbuilder_out = scratch_dir.join("jbuilder_types")
      override_dir = jbuilder_out.join("legacy")
      register_jbuilder_writer!(jbuilder_out)
      write_template("posts/show.json.jbuilder", "json.ok true\n")

      # Standalone class (not a subclass of an existing serializer): it is
      # discovered through its own `base_classes` registration, which the
      # ensure below removes — a subclass would linger in `descendants`
      # until GC and pollute later examples' generation cycles.
      stub_const("MigOverrideUserSerializer", Class.new)
      MigOverrideUserSerializer.class_eval do
        include Alba::Resource
        include Typelizer::DSL

        typelizer_config { |c| c.output_dir = override_dir }
        typelize_from ::User
        attributes :id, :username
      end

      # Full multi-writer pass: the default writer emits the override
      # interface into `jbuilder_out/legacy` BEFORE the jbuilder writer's
      # stale-file cleanup globs `jbuilder_out/**` — the override dir must be
      # in the protected set or the file is collected as stale.
      Typelizer::Generator.call(force: false)

      expect(override_dir.join("MigOverrideUser.ts")).to exist
      expect(jbuilder_out.join("PostsShow.ts")).to exist
    ensure
      Typelizer.base_classes.delete("MigOverrideUserSerializer")
    end
  end

  describe "cross-plugin duplicate-export detection" do
    it "warns when two plugins resolve to the same exported type name in one index, naming both sources" do
      shared_out = scratch_dir.join("shared_types")
      configuration.writer(:mig_shared) do |w|
        w.output_dir = shared_out
        w.reject_class = ->(serializer:) {
          serializer.name != "Alba::PostSerializer" &&
            !serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::")
        }
      end
      template_path = write_template("posts/_post.json.jbuilder", <<~RUBY)
        typelize_as "AlbaPost"

        json.id post.id, typelize: "number"
      RUBY

      logs = with_capture_logger { run_writer!(:mig_shared) }

      expect(logs).to include('duplicate exported type "AlbaPost"')
      expect(logs).to include("Alba::PostSerializer")
      expect(logs).to include(template_path)
      expect(logs).to include("index.ts")
      # Warning only — generation still completes.
      expect(shared_out.join("index.ts")).to exist
    end

    it "warns once per duplicate name-set across cycles and re-warns when the set changes" do
      shared_out = scratch_dir.join("dedup_types")
      configuration.writer(:mig_dedup) do |w|
        w.output_dir = shared_out
        w.reject_class = ->(serializer:) {
          !%w[Alba::PostSerializer Alba::UserSerializer].include?(serializer.name) &&
            !serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::")
        }
      end
      write_template("posts/_post.json.jbuilder", <<~RUBY)
        typelize_as "AlbaPost"

        json.id post.id, typelize: "number"
      RUBY

      first = with_capture_logger { run_writer!(:mig_dedup) }
      second = with_capture_logger { run_writer!(:mig_dedup) }

      # Same unchanged duplicate set: warn on the first cycle only.
      expect(first).to include('duplicate exported type "AlbaPost"')
      expect(second).not_to include("duplicate exported type")

      # The colliding set changes (a second collision appears): warn again.
      write_template("users/_user.json.jbuilder", <<~RUBY)
        typelize_as "AlbaUser"

        json.id user.id, typelize: "number"
      RUBY

      third = with_capture_logger { run_writer!(:mig_dedup) }
      expect(third).to include('duplicate exported type "AlbaPost"')
      expect(third).to include('duplicate exported type "AlbaUser"')
    end

    it "does not warn when the same-named types live in separate writers (the supported migration setup)" do
      alba_out = scratch_dir.join("alba_types")
      jbuilder_out = scratch_dir.join("jbuilder_types")
      register_alba_writer!(alba_out)
      register_jbuilder_writer!(jbuilder_out)
      write_template("posts/_post.json.jbuilder", <<~RUBY)
        typelize_as "AlbaPost"

        json.id post.id, typelize: "number"
      RUBY

      logs = with_capture_logger do
        run_writer!(:mig_alba)
        run_writer!(:mig_jbuilder)
      end

      expect(logs).not_to include("duplicate exported type")
      expect(alba_out.join("AlbaPost.ts")).to exist
      expect(jbuilder_out.join("AlbaPost.ts")).to exist
    end
  end
end
