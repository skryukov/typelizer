# frozen_string_literal: true

RSpec.describe Typelizer::Jbuilder do
  describe ".derive_type_name (via public template registration)" do
    let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-spec") }

    # Spec type names (`Post`, `User`, …) collide with the spec app's
    # templates, and colliding registrations now raise `NameCollision` —
    # start every example from a clean registry. No rehydration needed
    # afterwards: every generation cycle re-discovers from `jbuilder_views`.
    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(views_root)
    end

    def register(relative_path)
      full = File.join(views_root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "")
      Typelizer::Jbuilder.template(relative_path, views_root: views_root).name.split("::").last
    end

    it "collapses `<resource>/_<resource>` partials to the basename" do
      expect(register("posts/_post.json.jbuilder")).to eq("Post")
      expect(register("users/_user.json.jbuilder")).to eq("User")
    end

    it "keeps the full path when the parent dir doesn't match the partial basename" do
      expect(register("admin/_user.json.jbuilder")).to eq("AdminUser")
      expect(register("users/_avatar.json.jbuilder")).to eq("UsersAvatar")
    end

    it "collapses additive partials (`<resource>/_<resource>_<suffix>`) — for trait composition" do
      expect(register("courses/_course_details.json.jbuilder")).to eq("CourseDetails")
      expect(register("users/_user_with_existing_chat.json.jbuilder")).to eq("UserWithExistingChat")
    end

    it "strips only the redundant resource dir from deeper paths" do
      expect(register("admin/users/_user.json.jbuilder")).to eq("AdminUser")
    end

    it "keeps the full path for non-partial templates" do
      expect(register("posts/index.json.jbuilder")).to eq("PostsIndex")
      expect(register("admin/posts/index.json.jbuilder")).to eq("AdminPostsIndex")
    end

    it "handles top-level partials without a parent dir" do
      expect(register("_user.json.jbuilder")).to eq("User")
    end

    it "honors an explicit `as:` override" do
      full = File.join(views_root, "shared/_shared_props.json.jbuilder")
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "")
      klass = Typelizer::Jbuilder.template("shared/_shared_props.json.jbuilder", views_root: views_root, as: "SharedProps")
      expect(klass.name.split("::").last).to eq("SharedProps")
    end

    it "exposes a `.exclude` helper for migration-time `reject_class` filters" do
      predicate = Typelizer::Jbuilder.exclude(/Resource\z/)

      alba_resource = Class.new {
        def self.name
          "Alba::PostResource"
        end
      }
      jbuilder_template = Class.new {
        def self.name
          "Typelizer::Jbuilder::Templates::Post"
        end
      }
      unrelated = Class.new {
        def self.name
          "FooBar"
        end
      }

      expect(predicate.call(serializer: alba_resource)).to be true
      expect(predicate.call(serializer: jbuilder_template)).to be false
      expect(predicate.call(serializer: unrelated)).to be false
    end

    it "honors `typelize_as` declared at the top of a template" do
      full = File.join(views_root, "shared/_shared_props.json.jbuilder")
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, <<~ERB)
        typelize_as "SharedProps"

        json.foo "bar"
      ERB

      Typelizer::Jbuilder.discover(views_root)
      expect(Typelizer::Jbuilder::Templates.const_defined?(:SharedProps, false)).to be true
      expect(Typelizer::Jbuilder::Templates.const_defined?(:SharedSharedProps, false)).to be false
    end

    it "honors `typelize_from` declared at the top of a template" do
      full = File.join(views_root, "things/_thing.json.jbuilder")
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, <<~ERB)
        typelize_from User

        json.foo "bar"
      ERB

      Typelizer::Jbuilder.discover(views_root)
      expect(Typelizer::Jbuilder::Templates::Thing._typelizer_model_name).to eq(User)
    end
  end

  describe "intersection types from composed partials" do
    let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-intersect-spec") }

    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(views_root)
    end

    def write_template(relative_path, body)
      full = File.join(views_root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
      full
    end

    def render_interface(klass)
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      iface = ctx.interface_for(klass)
      Typelizer::Renderer.call("interface.ts.erb", interface: iface)
    end

    it "intersects partials when a block body is purely `json.partial!` calls" do
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.id course.id, typelize: "number"
        json.title course.title, typelize: "string"
      ERB
      write_template("courses/_course_details.json.jbuilder", <<~ERB)
        json.description course.description, typelize: "string"
      ERB
      write_template("dashboard/courses/show.json.jbuilder", <<~ERB)
        json.course do
          json.partial! "courses/course", course: @course
          json.partial! "courses/course_details", course: @course
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      page = Typelizer::Jbuilder::Templates::DashboardCoursesShow
      output = render_interface(page)

      expect(output).to include("course: Course & CourseDetails")
      expect(output).to include("import type {Course, CourseDetails}")
    end

    it "unions nullability across `if/else` branches that emit the same property" do
      write_template("courses/_category.json.jbuilder", <<~ERB)
        json.id category.id, typelize: "number"
        json.name category.name, typelize: "string"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        if @course.category
          json.category @course.category, partial: "courses/category", as: :category
        else
          json.category nil, typelize: "Category | null"
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)

      expect(output).to match(/category: Category \| null/)
    end

    it "treats plural-looking singular nouns (`earnings`, `news`, `settings`) as singular" do
      write_template("teacher/_earnings.json.jbuilder", <<~ERB)
        json.total_cents total, typelize: "number"
      ERB
      write_template("teacher/payouts/index.json.jbuilder", <<~ERB)
        json.earnings @earnings, partial: "teacher/earnings", as: :total
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::TeacherPayoutsIndex)

      expect(output).to include("earnings: TeacherEarnings")
      expect(output).not_to match(/Array<TeacherEarnings>/)
    end

    it "intersects named partials with a trailing inline shape for mixed blocks" do
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.id course.id, typelize: "number"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        json.course do
          json.partial! "courses/course", course: @course
          json.note @note, typelize: "string"
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      page = Typelizer::Jbuilder::Templates::CoursesShow
      output = render_interface(page)

      expect(output).to include("course: Course & {")
      expect(output).to include("note: string")
      expect(output).to include("import type {Course}")
    end

    it "keeps a single composed partial as a plain named interface (no intersection)" do
      write_template("users/_user.json.jbuilder", <<~ERB)
        json.id user.id, typelize: "number"
      ERB
      write_template("users/show.json.jbuilder", <<~ERB)
        json.author do
          json.partial! "users/user", user: @user
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

      expect(output).to include("author: User;")
      expect(output).not_to include("&")
    end

    it "skips the trailing shape when the non-partial remainder emits no properties" do
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.id course.id, typelize: "number"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        json.course do
          json.partial! "courses/course", course: @course
          json.merge! extra_hash
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)

      expect(output).to include("course: Course;")
      expect(output).not_to include("Course & ")
    end

    it "leaves a collection `partial!` inside a mixed block on the merged-object path, not as a named member" do
      write_template("comments/_comment.json.jbuilder", <<~ERB)
        json.id comment.id, typelize: "number"
      ERB
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.title course.title, typelize: "string"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        json.course do
          json.partial! "courses/course", course: @course
          json.partial! "comments/comment", collection: @comments
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)

      # The collection partial's fields merge into the trailing inline shape
      # (with its existing warning); only the plain partial is named.
      expect(output).to include("course: Course & {")
      expect(output).to include("id: number")
    end

    it "deduplicates a partial composed twice in the same block" do
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.id course.id, typelize: "number"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        json.course do
          json.partial! "courses/course", course: @course
          json.partial! "courses/course", course: @other_course
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)

      expect(output).to include("course: Course;")
      expect(output).not_to include("Course & Course")
    end

    it "runs model inference inside the trailing shape of a mixed block" do
      write_template("courses/_course.json.jbuilder", <<~ERB)
        json.id course.id, typelize: "number"
      ERB
      write_template("courses/show.json.jbuilder", <<~ERB)
        typelize_from User

        json.course do
          json.partial! "courses/course", course: @course
          json.extract! user, :name
        end
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)

      expect(output).to include("course: Course & {")
      expect(output).to include("name: string")
    end
  end

  describe "typelize: assertions (user_asserted)" do
    let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-asserted-spec") }

    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(views_root)
    end

    def write_template(relative_path, body)
      full = File.join(views_root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
      full
    end

    def render_interface(klass)
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      iface = ctx.interface_for(klass)
      Typelizer::Renderer.call("interface.ts.erb", interface: iface)
    end

    it "survives model inference when the asserted type disagrees with a JSON-typed AR attribute" do
      write_template("users/show.json.jbuilder", <<~RUBY)
        typelize_from User

        json.attr_json user.attr_json, typelize: "string[]"
      RUBY

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

      expect(output).to include("attr_json: Array<string>")
      expect(output).not_to include("attr_json: unknown")
    end

    it "scopes a nested typelize: to its nesting level (no flat-key leak onto same-named top-level props)" do
      write_template("users/show.json.jbuilder", <<~RUBY)
        typelize_from User

        json.name user.name
        json.stats do
          json.name 123, typelize: "number"
        end
      RUBY

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

      expect(output).to include("name: string;")
      expect(output).to include("name: number;")
    end

    it "drops a removed typelize: on the next generation in the same process (no stale registry)" do
      path = write_template("widgets/show.json.jbuilder", <<~RUBY)
        json.score 1, typelize: "string"
      RUBY
      klass = Typelizer::Jbuilder.template("widgets/show.json.jbuilder", views_root: views_root)

      expect(render_interface(klass)).to include("score: string")

      # No cache reset needed: the parse cache is content-keyed, so the
      # edited source re-parses on the next walk.
      File.write(path, "json.score 1\n")

      expect(render_interface(klass)).to include("score: number")
    end

    it "does not mutate the serializer class and tolerates an empty-but-present _typelizer_attributes" do
      write_template("users/show.json.jbuilder", <<~RUBY)
        typelize_from User

        json.name user.name
        json.score 1, typelize: "string"
      RUBY

      Typelizer::Jbuilder.discover(views_root)
      klass = Typelizer::Jbuilder::Templates::UsersShow
      # Virtual classes include the DSL, so the `dsl_attrs` registry can be
      # present-but-empty (`respond_to?` true). It must stay inert and empty.
      klass.send(:ensure_type_store, :_typelizer_attributes)

      output = render_interface(klass)

      expect(output).to include("name: string")
      expect(output).to include("score: string")
      expect(klass._typelizer_attributes).to eq({})
    end
  end

  describe "walker correctness" do
    let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-walker-spec") }

    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(views_root)
    end

    def write_template(relative_path, body)
      full = File.join(views_root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
      full
    end

    def render_interface(klass)
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      iface = ctx.interface_for(klass)
      Typelizer::Renderer.call("interface.ts.erb", interface: iface)
    end

    # All walker warnings go through the configured `Typelizer.logger`
    # (never Kernel#warn) — capture them for assertions.
    def with_capture_logger
      io = StringIO.new
      original = Typelizer.logger
      Typelizer.logger = Logger.new(io)
      yield
      io.string
    ensure
      Typelizer.logger = original
    end

    describe "unless/else branch merging" do
      it "keeps else-branch-only props as present and optional" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          unless @minimal
            json.theme "dark"
          else
            json.compact true
            json.theme "light"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("compact?: boolean")
      end

      it "keeps props emitted in both unless branches required" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          unless @minimal
            json.theme "dark"
          else
            json.theme "light"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("theme: string")
        expect(output).not_to include("theme?:")
      end

      it "marks props optional when an unless has no else" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          unless @hidden
            json.public_id 42
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("public_id?: number")
      end
    end

    describe "if/elsif/else branch merging" do
      it "requires props present in every branch and widens the rest to optional" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @active
            json.status "active"
            json.reason "still active"
          elsif @blocked
            json.status "blocked"
          else
            json.status "idle"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("status: string")
        expect(output).not_to include("status?:")
        expect(output).to include("reason?: string")
      end

      it "merges nested conditionals inside a block at their own nesting level" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.profile do
            json.id 1
            if @admin
              json.role "admin"
            else
              json.role "user"
              json.limited true
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("role: string")
        expect(output).to include("limited?: boolean")
      end
    end

    describe "inertia kwarg interplay with branch merging" do
      it "widens to optional once when `inertia: :defer` sits inside a covered branch" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @full
            json.stats @data, inertia: :defer, typelize: "Record<string, number>"
          else
            json.stats nil, typelize: "Record<string, number>"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output.scan("stats?:").size).to eq(1)
        expect(output).to include("stats?: Record<string, number>")
      end

      it "widens to optional when only a non-first branch defers the prop" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @cheap
            json.metrics nil, typelize: "Record<string, number>"
          else
            json.metrics @metrics, inertia: :defer, typelize: "Record<string, number>"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("metrics?: Record<string, number>")
      end
    end

    describe "warnings for silently dropped constructs" do
      it "warns through the configured logger for `json.merge!` and skips the construct" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.ok true
          json.merge! extra_hash
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("json.merge!")
        expect(logs).to include("typelize:")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("merge")
      end

      it "warns for dynamic `json.set!`" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.set! dynamic_key, some_value
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("json.set!")
        expect(logs).to include("typelize:")
      end

      it "warns when a `json.partial!` cannot be resolved instead of dropping silently" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.partial! "missing/thing"
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("missing/thing")
      end

      it "warns when a collection `partial!` appears inside a block (typed as object, not array)" do
        write_template("comments/_comment.json.jbuilder", <<~RUBY)
          json.id comment.id, typelize: "number"
        RUBY
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.comments do
            json.partial! partial: "comments/comment", collection: @comments
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("collection:")
      end

      it "warns when a root `json.array!` hides inside a conditional (typed as object)" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          if @flag
            json.array! @items do
              json.id 1
            end
          else
            json.empty true
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder")
        expect(logs).to include("array!")
        expect(logs).to match(/object/)
      end

      it "routes metadata read failures through the configured logger, not Kernel#warn" do
        path = write_template("misc/show.json.jbuilder", "json.ok true\n")
        walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!
        allow(walker).to receive(:parsed_tree).and_call_original
        allow(walker).to receive(:parsed_tree).with(path).and_raise(RuntimeError, "boom")

        logs = nil
        expect {
          logs = with_capture_logger { walker.metadata_for(path) }
        }.not_to output.to_stderr

        expect(logs).to include("failed to read metadata")
        expect(logs).to include("boom")
      end
    end

    describe "post-inference unknown warnings" do
      it "warns with file:line and a typelize: suggestion when the final type is unknown" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.ok true
          json.mystery some_helper_value
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("could not infer a type for `mystery`")
        expect(logs).to include('typelize: "string"')
        expect(logs).not_to include("`ok`")
      end

      it "warns for unknowns nested inside block shapes, at their own line" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.stats do
            json.total 1
            json.opaque some_helper_value
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:3")
        expect(logs).to include("could not infer a type for `opaque`")
        expect(logs).not_to include("`total`")
        expect(logs).not_to include("`stats`")
      end

      it "does not warn when model inference rescues a walker-unknown property" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.name user.name
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(output).to include("name: string")
        expect(logs).not_to include("could not infer a type")
      end

      it "does not warn when a name hint resolves the type" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.created_at some_helper_value
          json.posts_count some_helper_value
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).not_to include("could not infer a type")
      end

      it "does not warn for a user-asserted `typelize: \"unknown\"`" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.payload some_helper_value, typelize: "unknown"
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).not_to include("could not infer a type")
      end

      it "warns once per template+property per generation cycle (multi-writer dedup)" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.mystery some_helper_value
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          2.times { render_interface(Typelizer::Jbuilder::Templates::MiscShow) }
        end

        expect(logs.scan("could not infer a type for `mystery`").size).to eq(1)
      end

      it "warns again on the next cycle after reset! (per-cycle dedup, not forever)" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.mystery some_helper_value
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
          Typelizer::Jbuilder.reset!
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs.scan("could not infer a type for `mystery`").size).to eq(2)
      end
    end

    describe "partial resolution" do
      it "resolves a bare partial name against the current template's directory first" do
        write_template("posts/_post.json.jbuilder", <<~RUBY)
          json.id post.id, typelize: "number"
        RUBY
        write_template("posts/show.json.jbuilder", <<~RUBY)
          json.partial! "post"
          json.extra true
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)

        expect(output).to include("id: number")
        expect(output).to include("extra: boolean")
      end

      it "resolves kwargs-only `partial!` with a collection to a root array type" do
        write_template("posts/_post.json.jbuilder", <<~RUBY)
          json.id post.id, typelize: "number"
          json.title post.title, typelize: "string"
        RUBY
        write_template("posts/index.json.jbuilder", <<~RUBY)
          json.partial! partial: "posts/post", collection: @posts, as: :post
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PostsIndex)

        expect(output).to include("type PostsIndex = Array<PostsIndexData>")
        expect(output).to include("id: number")
        expect(output).to include("title: string")
      end

      it "warns when a kwargs-only `partial!` cannot be resolved" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.partial! partial: "missing/thing", collection: @things
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("missing/thing")
      end
    end

    describe "PORO typelize_from targets" do
      it "falls back to name heuristics for `extract!` without crashing" do
        stub_const("PoroProfile", Class.new)
        write_template("poros/show.json.jbuilder", <<~RUBY)
          typelize_from PoroProfile

          json.extract! profile, :id, :name, :created_at, :follower_count
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::PorosShow)
        end

        expect(output).to include("id: number")
        expect(output).to include("created_at: string")
        expect(output).to include("follower_count: number")
        expect(output).to include("name: unknown")
        # The post-inference unknown warning fires for the one prop that
        # neither name hints nor (absent) column inference could type.
        expect(logs).to include("could not infer a type for `name`")
      end
    end

    describe "dynamic `partial:` references" do
      it "walks without crashing, warns, and falls back to unknown typing" do
        write_template("misc/show.json.jbuilder", <<~'RUBY')
          json.author @user, partial: "users/#{kind}", as: :user
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("dynamic template reference")
        expect(logs).to include("typelize:")
        expect(output).to include("author: unknown")
      end
    end

    describe "dynamic `typelize:` values" do
      it "ignores non-literal overrides with a warning and falls back to inference" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.flag true, typelize: SOME_TYPE
          json.label label_value, typelize: type_var
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("`typelize:` with a non-literal value")
        expect(output).to include("flag: boolean")
        expect(output).to include("label: unknown")
        expect(output).not_to include("#<Prism")
      end

      it "produces identical output across two generation cycles (no node-inspect garbage)" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.flag true, typelize: SOME_TYPE
        RUBY

        first = second = nil
        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          first = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
          Typelizer::Jbuilder.reset!
          Typelizer::Jbuilder.discover(views_root)
          second = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(first).to eq(second)
      end
    end

    describe "same-name properties at one statement level" do
      it "merges an unconditional and a conditional emit into a single required key (first type wins)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.foo "a"

          if @extended
            json.foo 1
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output.scan(/\bfoo\??:/).size).to eq(1)
        expect(output).to include("foo: string")
        expect(output).not_to include("foo?:")
      end

      it "merges duplicates inside a block shape at that level" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.stats do
            json.count 1
            if @extended
              json.count 2
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output.scan(/\bcount\??:/).size).to eq(1)
        expect(output).to include("count: number")
      end
    end

    describe "unreadable templates" do
      it "raises Typelizer::Error naming the template path on the property-walk path" do
        walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!
        missing = File.join(views_root, "nope/missing.json.jbuilder")

        expect { walker.parsed_tree(missing) }
          .to raise_error(Typelizer::Error, /nope\/missing\.json\.jbuilder/)
      end
    end

    describe "nil literals" do
      it "types `json.note nil` as `null` exactly once" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.note nil
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("note: null;")
        expect(output).not_to include("null | null")
      end

      it "still widens a nil-emitting branch into `| null`" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @full
            json.summary "text"
          else
            json.summary nil
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("summary: string | null")
      end
    end

    describe "cyclic `json.partial!` merges" do
      it "breaks the cycle with a warning instead of overflowing the stack" do
        write_template("cycles/_a.json.jbuilder", <<~RUBY)
          json.a_field 1
          json.partial! "cycles/b"
        RUBY
        write_template("cycles/_b.json.jbuilder", <<~RUBY)
          json.b_field 2
          json.partial! "cycles/a"
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::CyclesA)
        end

        expect(logs).to include("cyclic `json.partial!` merge")
        expect(logs).to include("_a.json.jbuilder")
        expect(logs).to include("_b.json.jbuilder")
        expect(output).to include("a_field: number")
        expect(output).to include("b_field: number")
      end
    end

    describe "block-argument forms" do
      it "does not crash on `json.items @items, &renderer`" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @items, &renderer
        RUBY

        output = nil
        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("items: unknown")
      end
    end

    describe "unwalked control flow (case/while)" do
      it "warns when a case/when body contains json properties and emits nothing for it" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.ok true

          case @kind
          when "a"
            json.foo 1
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("things/show.json.jbuilder:3")
        expect(logs).to include("`case` body")
        expect(logs).to include("typelize:")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("foo")
      end

      it "warns when a while body contains json properties" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          while @more
            json.bar 1
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("`while` body")
      end

      it "stays silent for control flow without json calls" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          case @kind
          when "a" then helper_call
          end
          json.ok true
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).not_to include("`case` body")
      end
    end

    describe "discovery ordering" do
      it "registers templates in sorted path order regardless of FS glob order" do
        write_template("bbb/index.json.jbuilder", "json.x 1\n")
        write_template("aaa/index.json.jbuilder", "json.x 1\n")

        unsorted = [
          File.join(views_root, "bbb/index.json.jbuilder"),
          File.join(views_root, "aaa/index.json.jbuilder")
        ]
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob)
          .with(File.join(views_root, "**/*.json.jbuilder"))
          .and_return(unsorted)

        Typelizer::Jbuilder.discover(views_root)

        registered = Typelizer::Jbuilder.registry.keys.select { |k| k.start_with?(views_root) }
        expect(registered).to eq(registered.sort)
      end
    end
  end
end
