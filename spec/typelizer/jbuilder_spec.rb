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
      write_template("teacher/_news.json.jbuilder", <<~ERB)
        json.headline item, typelize: "string"
      ERB
      write_template("teacher/_settings.json.jbuilder", <<~ERB)
        json.theme prefs, typelize: "string"
      ERB
      write_template("teacher/payouts/index.json.jbuilder", <<~ERB)
        json.earnings @earnings, partial: "teacher/earnings", as: :total
        json.news @news, partial: "teacher/news", as: :item
        json.settings @settings, partial: "teacher/settings", as: :prefs
      ERB

      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::TeacherPayoutsIndex)

      expect(output).to include("earnings: TeacherEarnings")
      expect(output).to include("news: TeacherNews")
      expect(output).to include("settings: TeacherSettings")
      expect(output).not_to include("Array<")
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

    describe "coverage hardening (re-review round 3)" do
      it "types a singular-named prop backed by a relation-builder call as an array" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.result @posts.where(published: true), :id, :title
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        # `where` marks the value as a collection even though "result" is
        # singular — flipping to a plain object would be a silent wrong type.
        expect(output).to include("result: Array<")
        expect(output).to include("id: number")
      end

      it "emits NO warnings for a template using only supported constructs" do
        write_template("users/_user.json.jbuilder", <<~RUBY)
          json.name user.name, typelize: "string"
        RUBY
        write_template("users/index.json.jbuilder", <<~RUBY)
          json.partial! partial: "users/user", collection: @users, as: :user
        RUBY
        write_template("users/show.json.jbuilder", <<~RUBY)
          json.id 1
          json.profile do
            json.bio "text"
          end
          if @admin
            json.notes "x"
          end
          json.extract! person, :person_id
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::UsersIndex)
          render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        # A false-positive warning here would fail user builds under
        # config.strict — clean templates must stay silent.
        expect(logs).to eq("")
      end

      it "passes cache_if! contents through without widening or warning" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.cache_if! @cond, "key" do
            json.name "x"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("name: string")
        expect(output).not_to include("name?:")
        expect(logs).to eq("")
      end

      it "types `json.set!` with a literal key, a value, AND a block as an array" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.set! "records", @records do |record|
            json.label "x"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("records: Array<")
        expect(output).to include("label: string")
      end

      it "widens all keys optional when a blockless child! contributes an empty element" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.comments do
            json.child! do
              json.body "x"
            end
            json.child!
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("comments: Array<")
        expect(output).to include("body?: string")
      end

      it "still extracts literal attributes when key_format! is present (warning fires once)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.key_format! camelize: :lower
          json.extract! person, :id
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("key_format!")
        expect(logs.scan("key_format!").size).to eq(1)
        expect(output).to include("id: number")
      end
    end

    describe "literal types vs model inference (re-review round 3)" do
      it "keeps a literal value's type when a same-named model column exists" do
        write_template("posts/show.json.jbuilder", <<~RUBY)
          typelize_from Post
          json.title 42
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)

        # The template demonstrably renders a number; the string (nullable)
        # `title` column must not overwrite it or inject `| null`.
        expect(output).to include("title: number")
        expect(output).not_to include("string")
        expect(output).not_to include("null")
      end

      it "still lets the model fill in extracted attributes" do
        write_template("posts/show.json.jbuilder", <<~RUBY)
          typelize_from Post
          json.extract! post, :title
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)

        expect(output).to include("title: string | null")
      end
    end

    describe "value-level conditionals (re-review round 3)" do
      it "types a ternary with a nil arm as nullable" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.deleted_at @deleted ? Time.current.iso8601 : nil
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("deleted_at: string | null")
      end

      it "unions differing literal ternary arms" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.value @flag ? 1 : "s"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to match(/value: (number \| string|string \| number)/)
      end

      it "keeps the nullability signal when the non-nil arm is opaque but name-hinted" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.updated_at @dirty ? compute_stamp : nil
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("updated_at: string | null")
      end
    end

    describe "walk-time warning coverage (re-review round 3)" do
      it "warns when a splat value accompanies a block (array-vs-object undecidable)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.stuff(*@things) do
            json.label "x"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("splat value with a block")
        expect(output).to include("stuff: Array<")
      end

      it "warns on an unbalanced typelize: string instead of emitting broken TS" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.config @config, typelize: "{ broken"
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("unbalanced")
        expect(output).not_to include("{ broken")
      end

      it "accepts balanced typelize: strings with arrows and quoted brackets" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.handler @h, typelize: "(x: string) => void"
          json.paren @p, typelize: "'(' | ')'"
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).not_to include("unbalanced")
      end

      it "warns and emits nothing for a template with a Ruby syntax error (recovered AST lies)" do
        # The missing `end` makes Prism recover by folding `always_present`
        # under the unclosed `if` — walking that tree would silently type it
        # optional.
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @detailed
            json.details "x"
          json.always_present true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
          # Second render in the same cycle: the warning stays deduped.
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("syntax error")
        expect(logs).to include("things/show.json.jbuilder")
        expect(logs.scan("syntax error").size).to eq(1)
        expect(output).not_to include("always_present")
        expect(output).not_to include("details")
      end

      it "warns once per nesting level for same-named unknowns, each with its own line" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.foo mystery
          json.nested do
            json.foo other_mystery
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs.scan("could not infer a type for `foo`").size).to eq(2)
        expect(logs).to include("things/show.json.jbuilder:1")
        expect(logs).to include("things/show.json.jbuilder:3")
      end
    end

    describe "builder rebinding via it/_1/child! params (re-review round 3)" do
      it "recognizes `it` as the builder inside a parameterless object block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            it.name "x"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("author: {")
        expect(output).to include("name: string")
      end

      it "recognizes `_1` as the builder inside a parameterless object block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            _1.name "x"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("name: string")
      end

      it "recognizes a `json.child!` block param as the builder (child! yields self)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.comments do
            json.child! do |j|
              j.content "hello"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("comments: Array<")
        expect(output).to include("content: string")
      end

      it "shadows an outer builder alias when an array block reuses its name (no phantom props)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.stats do |json|
            json.items @records do |json|
              json.label "x"
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        # At runtime the inner param is each element of @records, so
        # `json.label` never reaches the builder — typing it would be a
        # phantom prop.
        expect(output).not_to include("label")
        expect(logs).to include("shadows the JSON builder")
      end

      it "warns when an array block param is named `json` (element calls render nothing)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @records do |json|
            json.label "x"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).not_to include("label")
        expect(logs).to include("shadows the JSON builder")
      end

      it "shadows an outer `it` alias inside a nested array block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.stats do
            it.items @records do
              it.label "x"
            end
          end
        RUBY

        output = nil
        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        # The inner `it` is the collection element, not the builder.
        expect(output).to include("items: Array<")
        expect(output).not_to include("label")
      end

      it "does not warn when the shadowing param is only READ (legitimate element access)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do |a|
            json.posts @posts do |a|
              json.title a, typelize: "string"
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        # The template renders and types correctly — a warning here is a
        # false positive that fails strict builds on correct code.
        expect(logs).not_to include("shadows")
        expect(output).to include("title: string")
      end

      it "still warns when the shadowing param is written through as a builder" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do |a|
            json.posts @posts do |a|
              a.title "x"
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        # `a` is the collection element here; `a.title "x"` renders nothing.
        expect(logs).to include("shadows the JSON builder")
        expect(output).not_to include("title")
      end
    end

    describe "duplicate-key re-set semantics (re-review round 3)" do
      it "last unconditional write wins for scalars (jbuilder replaces on re-set)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.status 1
          json.status "active"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("status: string")
        expect(output).not_to include("number")
      end

      it "an own prop after a merged partial overrides the partial's type" do
        write_template("things/_thing.json.jbuilder", <<~RUBY)
          json.status 1
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.partial! "things/thing"
          json.status "active"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("status: string")
      end

      it "deep-merges two object blocks for the same key (jbuilder _merge_block)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            json.name "x"
          end
          json.author do
            json.age 1
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("name: string")
        expect(output).to include("age: number")
      end

      it "marks keys arriving from a conditional block re-merge as optional" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            json.name "x"
          end
          if @admin
            json.author do
              json.notes "internal"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("name: string")
        expect(output).to include("notes?: string")
        expect(output).to include("author: {")
      end

      it "unions a conditional scalar re-write with the unconditional type" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.value "s"
          if @numeric
            json.value 1
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to match(/value: (string \| number|number \| string)/)
        expect(output).not_to include("value?:")
      end
    end

    describe "re-set semantics (round 4)" do
      # jbuilder is last-write-wins: `typelize:` annotates a WRITE, so an
      # assertion whose value never survives to render is dead.
      it "lets a later unconditional write override an earlier typelize: assertion" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.status @raw, typelize: "number"
          json.status "active"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("status: string")
        expect(output).not_to include("number")
      end

      it "lets an own unconditional write override a merged partial's asserted prop" do
        write_template("things/_thing.json.jbuilder", <<~RUBY)
          json.name @thing_name, typelize: "string"
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.partial! "things/thing"
          json.name 42
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("name: number")
        expect(output).not_to include("name: string")
      end

      it "honors the LAST of two typelize: assertions (statement order, like the render)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.v @a, typelize: "number"
          json.v @b, typelize: "string"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("v: string")
        expect(output).not_to include("number")
      end

      it "unions a trailing conditional re-set with a surviving assertion" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.v @a, typelize: "number"
          json.v "degraded" if @fallback
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("v: number | string")
      end

      # The union of an array block and a scalar keeps Array<> on ITS side of
      # the union — the scalar never lives inside the array.
      it "keeps Array<> on the array side when an array block is conditionally re-set with a scalar" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @items do |i|
            json.id i, typelize: "number"
          end
          json.items "unavailable" if @degraded
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("items: Array<{")
        expect(output).to include("}> | string;")
        expect(output).not_to match(/Array<[^>]*string/m)
      end

      it "keeps the Array<> wrapper when the array block is the conditional side" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items "empty"
          if @full
            json.items @items do |i|
              json.id i, typelize: "number"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("items: string | Array<{")
        expect(output).to include("id: number")
      end

      # Mirror image of "keys arriving from a conditional block re-merge are
      # optional": when the EARLIER block is the conditional one, a render
      # where only the unconditional block ran lacks its keys.
      it "widens the earlier conditional block's own keys when deep-merged with a later unconditional block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @admin
            json.author do
              json.internal_note "x"
            end
          end
          json.author do
            json.name "y"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("internal_note?: string")
        expect(output).to include("name: string")
        expect(output).to include("author: {")
      end

      it "unions a key shared by both blocks when the later block is conditional (deep merge, same key)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            json.name "x"
          end
          if @legacy
            json.author do
              json.name 1
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("name: string | number")
        expect(output).not_to include("name?:")
      end

      it "runs model inference inside union members (block shape conditionally re-set with a scalar)" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.payload do
            json.extract! @user, :id, :name
          end
          json.payload "redacted" if @hidden
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

        expect(output).to include("id: number")
        expect(output).to include("name: string")
        expect(output).to include("} | string")
      end

      it "warns for unknown props inside union members (strict builds must see them)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.payload do
            json.mystery some_helper
          end
          json.payload "redacted" if @hidden
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("could not infer a type for `mystery`")
        expect(logs).to include("things/show.json.jbuilder:2")
      end

      it "does not render null | null for an unconditional nil plus a conditional nil re-set" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.legacy nil
          json.legacy nil if @flag
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("legacy: null;")
        expect(output).not_to include("null | null")
      end

      it "widens to | null when a conditional bare nil re-sets a literal" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.foo 1
          json.foo nil if @redacted
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("foo: number | null")
      end

      # `A & B | C` binds as `A & (B | C)` in TS — the union of an
      # intersection type is not expressible, so it must warn + `unknown`,
      # never render silently wrong.
      it "warns and emits unknown when a composed-partial (intersection) prop is conditionally re-set" do
        write_template("courses/_course.json.jbuilder", <<~RUBY)
          json.id course.id, typelize: "number"
        RUBY
        write_template("courses/_course_details.json.jbuilder", <<~RUBY)
          json.summary course.summary, typelize: "string"
        RUBY
        write_template("courses/show.json.jbuilder", <<~RUBY)
          json.course do
            json.partial! "courses/course"
            json.partial! "courses/course_details"
          end
          json.course "hidden" if @restricted
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)
        end

        expect(logs).to include("not statically expressible")
        expect(output).to include("course: unknown")
        expect(output).not_to include("Course | ")
      end
    end

    describe "root array detection (re-review round 3)" do
      it "types `json.(collection) { |el| ... }` as a root array (jbuilder's call form)" do
        write_template("people/index.json.jbuilder", <<~RUBY)
          json.(@people) do |person|
            json.full_name "x"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PeopleIndex)

        expect(output).to include("type PeopleIndex = Array<PeopleIndexData>")
        expect(output).to include("full_name: string")
      end

      it "sees a root array through a cache! wrapper" do
        write_template("items/index.json.jbuilder", <<~RUBY)
          json.cache! "items" do
            json.array! @items do |item|
              json.label "x"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ItemsIndex)

        expect(output).to include("type ItemsIndex = Array<ItemsIndexData>")
        expect(output).to include("label: string")
      end

      it "sees a root collection partial through cache_root! with no spurious warning" do
        write_template("users/_user.json.jbuilder", <<~RUBY)
          json.name user.name, typelize: "string"
        RUBY
        write_template("users/index.json.jbuilder", <<~RUBY)
          json.cache_root! "users" do
            json.partial! partial: "users/user", collection: @users, as: :user
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersIndex)
        end

        expect(output).to include("type UsersIndex = Array<UsersIndexData>")
        expect(output).to include("name: string")
        expect(logs).not_to include("collection")
      end

      it "types a blockless root `json.array! @xs, :attrs` as a root array of the attribute shape" do
        write_template("people/index.json.jbuilder", <<~RUBY)
          json.array! @people, :id, :name
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PeopleIndex)

        expect(output).to include("type PeopleIndex = Array<PeopleIndexData>")
        expect(output).to include("id: number")
      end

      it "warns on a root array nested two conditionals deep" do
        write_template("items/index.json.jbuilder", <<~RUBY)
          if @a
            if @b
              json.array! @items do |item|
                json.id item.id
              end
            end
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ItemsIndex)
        end

        expect(logs).to include("conditional root arrays are not supported")
      end

      it "drops a conditional root array's element props instead of leaking them into the root shape" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @flag
            json.array! @xs do |x|
              json.element_field x, typelize: "number"
            end
          else
            json.total 5
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("conditional root arrays are not supported")
        # `element_field` describes array ELEMENTS of the warned-about branch;
        # the else branch's props survive as usual.
        expect(output).not_to include("element_field")
        expect(output).to include("total?: number")
      end

      it "drops a conditional root collection partial's props instead of merging them into the root shape" do
        write_template("users/_user.json.jbuilder", <<~RUBY)
          json.name user.name, typelize: "string"
        RUBY
        write_template("users/index.json.jbuilder", <<~RUBY)
          if @full
            json.partial! partial: "users/user", collection: @users, as: :user
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersIndex)
        end

        expect(logs).to include("conditional root arrays are not supported")
        expect(output).not_to match(/name\??:/)
      end
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

    describe "re-review regression fixes" do
      it "types a singular attribute-shortcut as an object, not an array" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author @author, :name, :email
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("author: {")
        expect(output).not_to include("author: Array<")
      end

      it "types a plural attribute-shortcut as an array" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.authors @authors, :name, :email
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("authors: Array<")
      end

      it "treats plural-looking aggregate names (metadata/data/stats/credentials) as singular objects" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.metadata @meta, :mean, :max
          json.data @payload, :size, :checksum
          json.stats @summary, :views, :clicks
          json.credentials @creds, :login, :token
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        %w[metadata data stats credentials].each do |name|
          expect(output).to include("#{name}: {")
          expect(output).not_to include("#{name}: Array<")
        end
      end

      it "lets a typelize: pin override the singular/plural heuristic" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.stats @all_stats, :mean, :max, typelize: "Array<{ mean: number }>"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("stats: Array<{ mean: number }>")
      end

      it "warns and falls back to inference when typelize: is a Ruby hash, not a type string" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.foo bar, typelize: {id: "number"}
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = nil
        logs = with_capture_logger do
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("non-literal value cannot be honored")
        expect(output).not_to include(%({id: "number"}))
      end

      it "warns and emits unknown for a value-less typelize: (its hash renders as the value)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.metadata typelize: "Record<string, string>"
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = nil
        logs = with_capture_logger do
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("`typelize:` without a value or block")
        expect(logs).to include("things/show.json.jbuilder:1")
        # The generic post-inference unknown warning is suppressed — one
        # warning per construct, not two.
        expect(logs).not_to include("could not infer a type for `metadata`")
        expect(output).to include("metadata: unknown")
        expect(output).not_to include("Record<string, string>")
      end

      it "warns when json.array! with a block is nested inside another block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.wrapper do
            json.array! @items do |item|
              json.id item.id
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        logs = with_capture_logger do
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("inside another block is typed as an object, not an array")
      end

      it "does not warn for a root-level json.array! block" do
        write_template("things/index.json.jbuilder", <<~RUBY)
          json.array! @items do |item|
            json.id item.id
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        logs = with_capture_logger do
          render_interface(Typelizer::Jbuilder::Templates::ThingsIndex)
        end

        expect(logs).not_to include("inside another block")
      end

      it "reads typelize_as declared after a json.* line" do
        path = write_template("things/show.json.jbuilder", <<~RUBY)
          json.ping true
          typelize_as "CustomThing"
        RUBY

        walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!
        expect(walker.metadata_for(path)[:type_name]).to eq("CustomThing")
      end

      it "ignores typelize_as/typelize_from metadata from a syntax-broken template (recovered tree is untrustworthy)" do
        path = write_template("trap/show.json.jbuilder", <<~RUBY)
          typelize_as "SyntaxTrap"
          typelize_from User

          json.foo do
            json.bar 1
        RUBY

        walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!
        metadata = nil
        with_capture_logger { metadata = walker.metadata_for(path) }

        expect(metadata).to eq({type_name: nil, model: nil})

        # Registration therefore falls back to the path-derived name.
        with_capture_logger { Typelizer::Jbuilder.discover(views_root) }
        expect(Typelizer::Jbuilder::Templates.const_defined?(:TrapShow, false)).to be true
        expect(Typelizer::Jbuilder::Templates.const_defined?(:SyntaxTrap, false)).to be false
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

    describe "`json.set!` with literal keys" do
      it "types a literal string key and quotes the abnormal name in the output" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.set! "kebab-key", "value"
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(output).to include("'kebab-key': string;")
        expect(logs).not_to include("json.set!")

        # TS-validity: the rendered property line must be a parseable
        # quoted-key member — <quote>name<same quote>(?)?: type;
        prop_line = output.lines.find { |l| l.include?("kebab-key") }.strip
        expect(prop_line).to match(/\A(['"])kebab-key\1\??: [^;]+;\z/)
      end

      it "treats a literal symbol key as a normal property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.set! :score, 42
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(output).to include("score: number;")
        expect(logs).not_to include("json.set!")
      end

      it "supports the block form under a literal string key" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.set! "meta-data" do
            json.ok true
          end
        RUBY

        output = nil
        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(output).to include("'meta-data': {")
        expect(output).to include("ok: boolean;")
      end
    end

    describe "block array-vs-object semantics and null-branch merging (regression)" do
      it "keeps the typed branch when a bare `nil` branch is listed first (if/else)" do
        # Regression: the type-supplying base was `present.first`, so a leading
        # `nil` branch collapsed the merged type to `null`, dropping `boolean`.
        write_template("misc/flags.json.jbuilder", <<~RUBY)
          if @admin
            json.flag nil
          else
            json.flag true
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscFlags)

        expect(output).to include("flag: boolean | null")
      end

      it "keeps the typed value when a bare `nil` precedes a typed re-emit (same level)" do
        # The `json.avatar_url nil; json.avatar_url ... if ...` placeholder idiom.
        write_template("misc/reemit.json.jbuilder", <<~RUBY)
          json.flag nil
          json.flag true if @cond
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscReemit)

        expect(output).to include("flag: boolean | null")
      end

      it "walks nested props when the block rebinds the json builder (`do |json|`)" do
        # Regression: `json.<x> do |json| ... end` rebinds the builder to a
        # local, so `json.name` had a LocalVariableRead receiver and was
        # silently dropped (as `Array<{}>`) with no warning.
        write_template("misc/rebind.json.jbuilder", <<~RUBY)
          json.author do |json|
            json.name a.name
            json.email a.email
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscRebind)

        expect(output).to include("author: {")
        expect(output).to include("name:")
        expect(output).to include("email:")
        expect(output).not_to include("author: Array")
      end

      it "types an object block that declares a block parameter as an object" do
        # jbuilder renders an object here (no positional value); the block param
        # must not flip it to an array.
        write_template("misc/wrap.json.jbuilder", <<~RUBY)
          json.author do |a|
            json.name a.name
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscWrap)

        expect(output).to include("author: {")
        expect(output).not_to include("author: Array")
      end

      it "types a block with a positional collection value as an array (param-less)" do
        # jbuilder renders an array iff a positional value accompanies the
        # block, regardless of whether the block declares a parameter.
        write_template("misc/list.json.jbuilder", <<~RUBY)
          json.items @items do
            json.ok true
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscList)

        expect(output).to include("items: Array<{")
        expect(output).to include("ok: boolean")
      end

      it "warns (not silently drops) on `json.extract!` with a splat object argument" do
        write_template("misc/dyn.json.jbuilder", <<~RUBY)
          json.extract! *attrs
        RUBY

        warnings = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscDyn)
        end

        expect(warnings).to include("dynamic attribute list")
      end
    end

    describe "`json.child!` array elements" do
      it "types a block of child! calls as an array, widening keys missing from some children (manifest shape)" do
        write_template("manifests/show.json.jbuilder", <<~RUBY)
          json.icons do
            json.child! do
              json.src image_path("icon-192.png")
              json.type "image/png"
              json.sizes "192x192"
            end
            json.child! do
              json.src image_path("icon-512.png")
              json.type "image/png"
              json.sizes "512x512"
            end
            json.child! do
              json.src image_path("icon-512-maskable.png")
              json.type "image/png"
              json.sizes "512x512"
              json.purpose "maskable"
            end
          end
        RUBY

        output = nil
        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ManifestsShow)
        end

        expect(output).to include("icons: Array<{")
        expect(output).to include("src: unknown;")
        expect(output).to include("type: string;")
        expect(output).to include("sizes: string;")
        expect(output).to include("purpose?: string;")
      end

      it "types a single child! block as an array of that shape with required keys" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.items do
            json.child! do
              json.id 1
              json.label "x"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)

        expect(output).to include("items: Array<{")
        expect(output).to include("id: number;")
        expect(output).to include("label: string;")
        expect(output).not_to include("id?:")
        expect(output).not_to include("label?:")
      end

      it "warns on mixed content (child! + named props) and types only the array elements" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.things do
            json.child! do
              json.id 1
            end
            json.total 5
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("mixing `json.child!` with named properties")
        expect(output).to include("things: Array<{")
        expect(output).to include("id: number;")
        expect(output).not_to include("total")
      end

      it "types child! inside a collection-value block as an array of arrays" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.comments @comments do |c|
            json.child! do
              json.body c, typelize: "string"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)

        # jbuilder renders one scope per collection element and `child!`
        # turns EACH scope into an array — [[{body}], [{body}]] at runtime.
        expect(output).to include("comments: Array<Array<{")
        expect(output).to include("body: string")
      end

      it "warns and skips child! at the template root" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.child! do
            json.id 1
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("json.child!")
        expect(logs).to include("template root")
        expect(output).not_to include("id:")
        expect(output).not_to include("child")
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
        expect(logs.scan("json.merge!").size).to eq(1)
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
        expect(logs.scan("json.set!").size).to eq(1)
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
        expect(logs.scan("missing/thing").size).to eq(1)
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
        expect(logs).to include("conditional root arrays are not supported")
        expect(logs.scan("conditional root arrays").size).to eq(1)
      end

      it "warns when a root collection `partial!` hides inside a conditional" do
        write_template("users/_user.json.jbuilder", <<~RUBY)
          json.name user.name, typelize: "string"
        RUBY
        write_template("misc/show.json.jbuilder", <<~RUBY)
          if @flag
            json.partial! partial: "users/user", collection: @users, as: :user
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("conditional root arrays are not supported")
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

    describe "root `json.array!` with `partial:`" do
      it "types the root as an array of the partial's named interface, with an import" do
        write_template("portals/_portal.json.jbuilder", <<~RUBY)
          json.id portal.id, typelize: "number"
          json.slug portal.slug, typelize: "string"
        RUBY
        write_template("portals/index.json.jbuilder", <<~RUBY)
          json.array! @portals, partial: "portals/portal", as: :portal
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PortalsIndex)

        expect(output).to include("type PortalsIndex = Array<Portal>;")
        expect(output).to include("import type {Portal}")
        # The element is referenced by name — no inline Data alias.
        expect(output).not_to include("PortalsIndexData")
      end

      it "is written (not dropped as empty) and exported despite having no own properties" do
        write_template("portals/_portal.json.jbuilder", <<~RUBY)
          json.id portal.id, typelize: "number"
        RUBY
        write_template("portals/index.json.jbuilder", <<~RUBY)
          json.array! @portals, partial: "portals/portal", as: :portal
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        ctx = Typelizer::WriterContext.new(writer_name: nil)
        iface = ctx.interface_for(Typelizer::Jbuilder::Templates::PortalsIndex)

        expect(iface.empty?).to be(false)
        expect(iface.imports).to include("Portal")
      end

      it "keeps the dynamic-partial warning for a non-literal `partial:` value (root stays an object)" do
        write_template("portals/index.json.jbuilder", <<~RUBY)
          json.array! @portals, partial: some_partial, as: :portal
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::PortalsIndex)
        end

        expect(logs).to include("portals/index.json.jbuilder:1")
        expect(logs).to include("dynamic template reference")
        expect(logs).to include("typelize:")
        expect(output).not_to include("Array<")
      end

      it "falls back to `Array<unknown>` with the unresolved-partial warning when the partial is missing" do
        write_template("portals/index.json.jbuilder", <<~RUBY)
          json.array! @portals, partial: "missing/portal", as: :portal
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::PortalsIndex)
        end

        expect(logs).to include("missing/portal")
        expect(logs).to include("could not be resolved")
        expect(output).to include("type PortalsIndex = Array<unknown>;")
        expect(output).not_to include("import type")
      end

      it "falls back to `Array<unknown>` with one warning when the partial resolves to an empty interface" do
        # The partial's only statement is fully dynamic — its walked
        # interface ends up with zero properties (dropped from generation),
        # so naming it would emit a dangling import.
        write_template("portals/_portal.json.jbuilder", <<~'RUBY')
          json.partial! "#{kind.pluralize}/attributes", kind: kind
        RUBY
        write_template("portals/index.json.jbuilder", <<~RUBY)
          json.array! @portals, partial: "portals/portal", as: :portal
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::PortalsIndex)
        end

        expect(logs).to include('partial "portals/portal" produced no statically-typed properties')
        expect(logs).to include("the root array element falls back to `unknown`")
        expect(output).to include("type PortalsIndex = Array<unknown>;")
        expect(output).not_to include("Array<Portal>")
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

    describe "empty partial references" do
      # An interface with zero properties is dropped from generation (no
      # .ts file, no index export — see Writer#call), so emitting a NAMED
      # reference to it would produce a dangling `import type` (TS2305).
      def write_empty_partial(relative_path = "profiles/_profile.json.jbuilder")
        # The only statement is a fully-dynamic `json.partial!`, which warns
        # and skips — the walked interface ends up with zero properties.
        write_template(relative_path, <<~'RUBY')
          json.partial! "#{kind.pluralize}/attributes", kind: kind
        RUBY
      end

      it "falls back to `unknown` (with one warning) when a `partial:` kwarg resolves to an empty interface" do
        write_empty_partial
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.profile @profile, partial: "profiles/profile", as: :profile
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("profile: unknown")
        expect(output).not_to include("Profile")
        expect(output).not_to include("import type")
        expect(logs).to include("things/show.json.jbuilder:1")
        expect(logs).to include('partial "profiles/profile" produced no statically-typed properties')
        expect(logs).to include("`profile` falls back to `unknown`")
        expect(logs).to include("typelize:")
        # One clear warning — the generic post-inference unknown warning is
        # suppressed for this prop instead of double-firing.
        expect(logs).not_to include("could not infer a type for `profile`")
      end

      it "warns once per reference site per generation cycle (multi-writer dedup)" do
        write_empty_partial
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.profile @profile, partial: "profiles/profile", as: :profile
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          2.times { render_interface(Typelizer::Jbuilder::Templates::ThingsShow) }
        end

        expect(logs.scan("produced no statically-typed properties").size).to eq(1)
      end

      it "keeps statically-known collection-ness: the collection form renders Array<unknown>" do
        write_empty_partial
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.profiles @profiles, partial: "profiles/profile", as: :profile
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("profiles: Array<unknown>")
        expect(output).not_to include("Profile")
        expect(logs).to include("produced no statically-typed properties")
      end

      it "omits an empty member from a block-composed intersection, keeping the other members intact" do
        write_empty_partial
        write_template("courses/_course.json.jbuilder", <<~RUBY)
          json.id course.id, typelize: "number"
        RUBY
        write_template("courses/show.json.jbuilder", <<~RUBY)
          json.course do
            json.partial! "courses/course", course: @course
            json.partial! "profiles/profile", profile: @profile
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)
        end

        expect(output).to include("course: Course;")
        expect(output).not_to include("Profile")
        expect(output).to include("import type {Course}")
        expect(logs).to include('partial "profiles/profile" produced no statically-typed properties')
        expect(logs).to include("omitted from `course`'s intersection type")
      end

      it "still supports recursive non-empty partials (in-progress walk is treated as non-empty)" do
        write_template("comments/_comment.json.jbuilder", <<~RUBY)
          json.id comment.id, typelize: "number"
          json.replies comment.replies, partial: "comments/comment", as: :comment
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::Comment)
        end

        expect(output).to include("replies: Array<Comment>")
        expect(logs).not_to include("produced no statically-typed properties")
      end

      it "handles a self-merging (cycle-guarded, hence empty) partial gracefully when referenced elsewhere" do
        # `loops/_loop` only merges itself: the cycle guard skips the merge,
        # so the interface ends up empty — a reference to it must degrade to
        # `unknown` instead of importing a dropped type.
        write_template("loops/_loop.json.jbuilder", <<~RUBY)
          json.partial! "loops/loop"
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.loop @loop, partial: "loops/loop", as: :loop
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("loop: unknown")
        expect(output).not_to include("import type")
        expect(logs).to include("cyclic `json.partial!` merge")
        expect(logs).to include('partial "loops/loop" produced no statically-typed properties')
      end

      it "never emits an import without a matching generated type (generation-level invariant)" do
        write_empty_partial
        write_template("posts/_post.json.jbuilder", <<~RUBY)
          json.id post.id, typelize: "number"
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.thing @x, partial: "profiles/profile", as: :profile
          json.other @y, partial: "posts/post", as: :post
          json.box do
            json.partial! "profiles/profile", profile: @x
            json.partial! "posts/post", post: @y
          end
        RUBY

        with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          ctx = Typelizer::WriterContext.new(writer_name: nil)
          interfaces = Typelizer::Jbuilder.registry.values.map { |klass| ctx.interface_for(klass) }
          # The writer drops empty interfaces from generation and index.ts.
          emitted = interfaces.reject(&:empty?)
          rendered = emitted.map { |i| Typelizer::Renderer.call("interface.ts.erb", interface: i) }

          exported = emitted.map(&:name)
          imported = rendered
            .flat_map { |src| src.scan(/import type \{([^}]+)\}/) }
            .flatten
            .flat_map { |list| list.split(",").map(&:strip) }

          expect(imported).to include("Post") # sanity: real imports survive
          expect(imported.uniq - exported).to eq([])
        end
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

    describe "iteration/expression wrapping json properties" do
      it "warns when top-level iteration wraps json calls and emits nothing for it" do
        write_template("repro/each_set.json.jbuilder", <<~RUBY)
          json.ok true
          @items.each do |item|
            json.set! item.code do
              json.secret_field item.name
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ReproEachSet)
        end

        expect(logs).to include("repro/each_set.json.jbuilder:2")
        expect(logs).to include("iteration or expression wrapping json properties cannot be statically typed")
        expect(logs).to include("typelize:")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("secret_field")
      end

      it "warns inside a block body too" do
        write_template("repro/show.json.jbuilder", <<~RUBY)
          json.summary do
            @rows.each { |row| json.set!(row.key, row.value) }
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ReproShow)
        end

        expect(logs).to include("repro/show.json.jbuilder:2")
        expect(logs).to include("iteration or expression wrapping json properties")
      end

      it "stays silent for plain non-json statements" do
        write_template("repro/show.json.jbuilder", <<~RUBY)
          total = @items.size
          helper_side_effect
          json.ok true
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ReproShow)
        end

        expect(logs).not_to include("iteration or expression")
      end
    end

    describe "cache_collection!" do
      # `cache_collection!` is NOT part of jbuilder 2.15's public API (it
      # lived in the external jbuilder_cache_multi gem): jbuilder routes it
      # through `method_missing`/`set!` and renders a literal
      # "cache_collection!" JSON key. The walker's `else` arm mirrors that —
      # a quoted property, warned as unknown — instead of a dead special case
      # (the API canary keeps the dispatch list honest in both directions).
      it "types the bare form as a plain (quoted) property, like jbuilder renders it" do
        write_template("probe/index.json.jbuilder", <<~RUBY)
          json.ok true
          json.cache_collection! @people
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ProbeIndex)
        end

        expect(output).to include("ok: boolean")
        expect(output).to include("'cache_collection!': unknown")
        # warn-on-drop: the untypeable value still warns through the normal
        # unknown-candidate path.
        expect(logs).to include("could not infer a type for `cache_collection!`")
        expect(logs).to include("probe/index.json.jbuilder:2")
      end
    end

    describe "dynamic extract!/call attribute lists" do
      it "warns once per call site and keeps the literal attributes" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.call(user, :name, *helper_attributes)
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(logs).to include("users/show.json.jbuilder:3")
        expect(logs).to include("dynamic attribute list")
        expect(logs).to include("only literal attributes emitted")
        expect(logs.scan("dynamic attribute list").size).to eq(1)
        expect(output).to include("name: string")
        expect(output).not_to include("helper_attributes")
      end

      it "stays silent for all-literal attribute lists" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.extract! user, :name
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(logs).not_to include("dynamic attribute list")
      end
    end

    describe "key_format! and ignore_nil!" do
      it "warns for `json.key_format!` (bare and with args) and emits no property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.key_format! camelize: :lower
          json.key_format!
          json.ok true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("changes runtime key casing")
        expect(logs).to include("properties_transformer")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("key_format")
      end

      it "warns for `json.ignore_nil!` (bare and with args) and emits no property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.ignore_nil!
          json.ignore_nil! false
          json.ok true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("omits nil-valued keys at runtime")
        expect(logs).to include("typelize:")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("ignore_nil")
      end

      it "warns for `json.deep_format_keys!` and emits no property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.deep_format_keys!
          json.deep_format_keys! false
          json.ok true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("key casing of nested")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("deep_format_keys")
      end

      it "warns for `json.nil!`/`json.null!` and emits no property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.nil!
          json.null!
          json.ok true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("renders `null` at runtime")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("nil!")
        expect(output).not_to include("null!")
      end

      it "warns for `json.attributes!`/`json.target!` and emits no property" do
        write_template("misc/show.json.jbuilder", <<~RUBY)
          json.attributes!
          json.target!
          json.ok true
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::MiscShow)
        end

        expect(logs).to include("misc/show.json.jbuilder:1")
        expect(logs).to include("misc/show.json.jbuilder:2")
        expect(logs).to include("jbuilder internal accessor")
        expect(output).to include("ok: boolean")
        expect(output).not_to include("attributes!")
        expect(output).not_to include("target!")
      end
    end

    describe "delegated union members (round 5)" do
      # A column occurrence folded into a union used to be silently DROPPED
      # (`Array(nil) == []`) and the merged prop poisoned with
      # `inference_locked`, so `extract! + conditional literal` emitted only
      # the literal's type. Renders (jbuilder 2.15.1): flag=false → `true`
      # (boolean), flag=true → "suspended" — the union must cover both.
      it "resolves an extract!-ed column unioned with a conditional literal through model inference" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.extract! @user, :active
          json.active "suspended" if @flag
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(output).to include("active: boolean | string")
        expect(logs).to eq("")
      end

      it "resolves the delegated member when the literal comes FIRST (reverse order)" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.name 42
          json.extract! @user, :name if @flag
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(output).to include("name: number | string")
        expect(logs).to eq("")
      end

      it "widens nullability by the delegated column's (nullable column + literal)" do
        write_template("posts/show.json.jbuilder", <<~RUBY)
          typelize_from Post

          json.extract! @post, :title
          json.title 0 if @legacy
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)

        # posts.title is a NULLABLE string column: the delegated occurrence
        # renders null when the column is null, so `| null` must survive.
        expect(output).to include("title: string | number | null")
      end

      it "dedupes the resolved column type against a same-typed literal without enum repainting" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.extract! @user, :role
          json.role "custom" if @override
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

        # users.role is an enum column (→ string) and the literal is a
        # string: the members dedupe to a plain `string`. The column's enum
        # metadata describes only ONE union member, so it must not repaint
        # the property as the named enum type.
        expect(output).to include("role: string")
        expect(output).not_to include("UserRole")
        expect(output).not_to include("string | string")
      end

      it "keeps a fully delegated re-set (extract! twice) on the plain column-inference path" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.extract! @user, :name
          json.extract! @user, :name if @again
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

        expect(output).to include("name: string")
        expect(output).not_to include("|")
      end

      it "degrades an unresolvable delegated member to `unknown` WITH a post-inference warning" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.extract! @thing, :mystery
          json.mystery "n/a" if @fallback
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("mystery: unknown | string")
        expect(logs).to include("could not infer a type for `mystery`")
        expect(logs).to include("things/show.json.jbuilder:1")
      end

      # `unknown | string` IS unknown in TS — strict builds must see it even
      # though the top-level type isn't the bare "unknown" string.
      it "warns when a union carries an untypeable member (no model involved)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.thing @x.compute
          json.thing "n/a" if @y
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("could not infer a type for `thing`")
        expect(logs.scan("could not infer a type for `thing`").size).to eq(1)
        expect(logs).to include("things/show.json.jbuilder:1")
      end
    end

    describe "explicit nil signals in values (round 5)" do
      # Pure hint/literal paths (no typelize_from): render-verified against
      # jbuilder 2.15.1 — each construct demonstrably renders null.
      it "types safe navigation as nullable (`@post&.created_at`)" do
        write_template("things/show.json.jbuilder", "json.created_at @post&.created_at\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("created_at: string | null")
      end

      it "types a deep safe-navigation chain as nullable with the property-name hint" do
        write_template("things/show.json.jbuilder", "json.total @cart&.items&.count\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("total: number | null")
      end

      it "types `try(:sym)` as nullable with the tried name's hint" do
        write_template("things/show.json.jbuilder", "json.updated_at @post.try(:updated_at)\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("updated_at: string | null")
      end

      it "types `.presence` as nullable, keeping the receiver's inferred type" do
        write_template("things/show.json.jbuilder", "json.published_at @row.published_at.presence\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("published_at: string | null")
      end

      it "types `a && b` as nullable from the right side (nil left leaks through)" do
        write_template("things/show.json.jbuilder", "json.is_admin @user && @user.admin\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("is_admin: boolean | null")
      end

      # `a || b` renders the fallback when a is nil — nil never survives, so
      # a literal fallback must NOT emit `| null` noise (that false `| null`
      # is exactly what strict frontends trip over).
      it "types `a || <literal>` from the fallback with NO null" do
        write_template("things/show.json.jbuilder", "json.title @x.title || \"Untitled\"\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("title: string;")
        expect(output).not_to include("title: string | null")
      end

      it "keeps `| null` on `a || b` only when the right side is itself nilable" do
        write_template("things/show.json.jbuilder", "json.updated_at @cache || @post.try(:updated_at)\n")

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("updated_at: string | null")
      end

      it "unwraps a parenthesized value (`json.x (cond ? a : nil)` with a space)" do
        write_template("a/show.json.jbuilder", "json.created_at (@post ? @post.created_at : nil)\n")
        write_template("b/show.json.jbuilder", "json.created_at(@post ? @post.created_at : nil)\n")

        Typelizer::Jbuilder.discover(views_root)
        spaced = render_interface(Typelizer::Jbuilder::Templates::AShow)
        tight = render_interface(Typelizer::Jbuilder::Templates::BShow)

        expect(tight).to include("created_at: string | null")
        expect(spaced).to include("created_at: string | null")
      end

      it "honors a parenthesized `typelize:` literal" do
        write_template("things/show.json.jbuilder", "json.payload @data, typelize: (\"string\")\n")

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("payload: string")
        expect(logs).to eq("")
      end

      # Composed behavior with a model binding: the walker's nullable:true
      # currently gets clobbered by column inference assigning (not widening)
      # nullability — active_record.rb's widen-not-assign fix lands
      # separately.
      it "keeps safe-navigation nullability over a NOT NULL column of the same name" do
        pending "requires model-inference widening in active_record.rb (merged separately)"
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          json.name @maybe_user&.name
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)

        expect(output).to include("name: string | null")
      end
    end

    describe "array concat semantics (round 5)" do
      # jbuilder's `_merge_block` → `_merge_values(Array, Array)` branch
      # CONCATENATES: a valueless `json.<key> do json.child! ... end` over an
      # existing array appends elements of the new shape. Render-verified
      # (jbuilder 2.15.1): [{a: 1}, {b: 2}].
      it "unions element types when a child!-block re-sets a collection block (concat)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @xs do |x|
            json.a x, typelize: "number"
          end
          json.items do
            json.child! do
              json.b 2
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to match(/items: Array<\{\s*a: number;\s*\} \| \{\s*b: number;\s*\}>/)
      end

      it "unions element types across two child!-blocks on the same key (concat)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items do
            json.child! do
              json.a 1
            end
          end
          json.items do
            json.child! do
              json.b 2
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("a: number")
        expect(output).to include("b: number")
        expect(output).to match(/items: Array<\{[\s\S]*\} \| \{[\s\S]*\}>/)
      end

      # The mirror order REPLACES (`_set` → `_set_value`): render keeps only
      # the collection block's elements.
      it "keeps replace semantics when a collection block re-sets a child!-block" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items do
            json.child! do
              json.b 2
            end
          end
          json.items @xs do |x|
            json.a x, typelize: "number"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("a: number")
        expect(output).not_to include("b:")
      end

      it "unions element types for a CONDITIONAL child!-block concat" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @xs do |x|
            json.a x, typelize: "number"
          end
          if @extra
            json.items do
              json.child! do
                json.b 2
              end
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        # Render truth: [{a:1}] or [{a:1},{b:2}] — element union, key present
        # either way.
        expect(output).to match(/items: Array<\{[\s\S]*a: number;[\s\S]*\} \| \{[\s\S]*b: number;[\s\S]*\}>/)
        expect(output).not_to include("items?:")
      end

      # A second root `json.array!` also concatenates
      # (`@attributes = _merge_values(Array, Array)`). The element type is
      # the union of both shapes; a flat property list can't express that,
      # so every merged element key widens to optional — and nothing is
      # silently dropped.
      it "merges a conditional second root array's element props as optional (no silent drop)" do
        write_template("things/index.json.jbuilder", <<~RUBY)
          json.array! @xs do |x|
            json.id 1
          end
          if @legacy
            json.array! @more do |m|
              json.extra 2
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsIndex)
        end

        expect(output).to include("type ThingsIndex = Array<ThingsIndexData>")
        expect(output).to include("id?: number")
        expect(output).to include("extra?: number")
        expect(logs).to eq("")
      end

      it "merges two unconditional root arrays' element props as optional (concat)" do
        write_template("things/index.json.jbuilder", <<~RUBY)
          json.array! @xs do |x|
            json.id 1
          end
          json.array! @more do |m|
            json.extra 2
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsIndex)

        expect(output).to include("id?: number")
        expect(output).to include("extra?: number")
      end

      it "keeps a single root array's element keys required (no spurious widening)" do
        write_template("things/index.json.jbuilder", <<~RUBY)
          json.array! @xs do |x|
            json.id 1
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsIndex)

        expect(output).to include("id: number")
        expect(output).not_to include("id?:")
      end
    end

    describe "unconditional block over a union (round 5)" do
      # Render truth (jbuilder 2.15.1): {id}-block + conditional "anon" +
      # {bio}-block renders {id, bio} when the scalar didn't run and raises
      # Jbuilder::MergeError when it did — the ONLY successful render deep-
      # merges the shapes, so the scalar member drops from the type.
      it "deep-merges an unconditional object block into a union's shape member" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.author do
            json.id 1
          end
          json.author "anon" if @hide
          json.author do
            json.bio "x"
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("id: number")
        expect(output).to include("bio: string")
        expect(output).not_to include("| string")
        expect(output).not_to include("unknown")
      end

      # Same principle for arrays: array + conditional scalar + child!-block
      # renders concat or crashes (verified) — the scalar member drops, the
      # element types union.
      it "drops a crash-only scalar member when a child!-block concatenates over the union" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.items @xs do |x|
            json.a x, typelize: "number"
          end
          json.items "none" if @empty
          json.items do
            json.child! do
              json.b 2
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to match(/items: Array<\{[\s\S]*\} \| \{[\s\S]*\}>/)
        expect(output).not_to include("none")
        expect(output).not_to include("| string")
      end

      it "warns and degrades when the union holds a named partial reference (inexpressible merge)" do
        write_template("courses/_course.json.jbuilder", <<~RUBY)
          json.id course.id, typelize: "number"
        RUBY
        write_template("courses/show.json.jbuilder", <<~RUBY)
          json.course @course, partial: "courses/course", as: :course
          json.course "closed" if @closed
          json.course do
            json.note "x"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::CoursesShow)
        end

        expect(logs).to include("not statically expressible")
        expect(output).to include("course: unknown")
      end
    end

    describe "intersection nullability (round 5)" do
      # `&` binds tighter than `|` in TS: `Course & CourseDetails | null` is
      # exactly `(Course & CourseDetails) | null` — a conditional bare nil
      # over an intersection is fully expressible and must not warn or
      # degrade (a false warning fails strict builds).
      it "widens a composed-partial (intersection) prop to | null on a conditional bare nil" do
        write_template("courses/_course.json.jbuilder", <<~RUBY)
          json.id course.id, typelize: "number"
        RUBY
        write_template("courses/_course_details.json.jbuilder", <<~RUBY)
          json.summary course.summary, typelize: "string"
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.course do
            json.partial! "courses/course"
            json.partial! "courses/course_details"
          end
          json.course nil if @hidden
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("course: Course & CourseDetails | null")
        expect(logs).to eq("")
      end

      it "widens to | null when the unconditional write is the bare nil (reverse order)" do
        write_template("courses/_course.json.jbuilder", <<~RUBY)
          json.id course.id, typelize: "number"
        RUBY
        write_template("courses/_course_details.json.jbuilder", <<~RUBY)
          json.summary course.summary, typelize: "string"
        RUBY
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.course nil
          if @visible
            json.course do
              json.partial! "courses/course"
              json.partial! "courses/course_details"
            end
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("course: Course & CourseDetails | null")
        expect(logs).to eq("")
      end
    end

    describe "shadowed-builder-param warning precision (round 5)" do
      # Reading THROUGH the shadowing name (`j[:amount]`, `j.fetch`) is
      # legitimate element access — the template renders correctly, so a
      # warning here is a false positive that fails strict builds.
      it "does not warn for read-only access through a shadowing block param" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.report do |j|
            j.rows @rows do |j|
              json.amount j[:amount], typelize: "number"
              json.details j.fetch(:details, nil), typelize: "string"
            end
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).not_to include("shadows the JSON builder")
      end

      it "still warns for a genuine write through the shadowing param" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          json.report do |j|
            j.rows @rows do |j|
              j.title "x"
            end
          end
        RUBY

        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(logs).to include("shadows the JSON builder")
      end
    end

    describe "cross-branch type unions (round 5)" do
      # Only one branch runs at render: `@flag1 ? 20 : @d1` demonstrably
      # renders `false` when @d1 is false, so emitting `number` alone was a
      # silent wrong type — and swallowing the `unknown` member also muted
      # the post-inference warning.
      it "unions disagreeing branch types and keeps the unknown member warning alive" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @flag1
            json.k2 20
          else
            json.k2 @d1
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("k2: number | unknown")
        expect(logs).to include("could not infer a type for `k2`")
      end

      it "unions two inferable branch types" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @numeric
            json.value 1
          else
            json.value "one"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)
        end

        expect(output).to include("value: number | string")
        expect(output).not_to include("value?:")
        expect(logs).to eq("")
      end

      it "unions branch object shapes (only one branch's shape renders)" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @admin
            json.payload do
              json.secret "x"
            end
          else
            json.payload do
              json.public_info "y"
            end
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("secret: string")
        expect(output).to include("public_info: string")
        expect(output).to match(/payload: \{[\s\S]*\} \| \{[\s\S]*\}/)
      end

      it "resolves a delegated branch member through model inference" do
        write_template("users/show.json.jbuilder", <<~RUBY)
          typelize_from User

          if @raw
            json.extract! @user, :active
          else
            json.active "suspended"
          end
        RUBY

        output = nil
        logs = with_capture_logger do
          Typelizer::Jbuilder.discover(views_root)
          output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
        end

        expect(output).to include("active: boolean | string")
        expect(logs).to eq("")
      end

      it "still lets a typelize: assertion in one branch win outright" do
        write_template("things/show.json.jbuilder", <<~RUBY)
          if @full
            json.stats @data, typelize: "Record<string, number>"
          else
            json.stats compute_stats
          end
        RUBY

        Typelizer::Jbuilder.discover(views_root)
        output = render_interface(Typelizer::Jbuilder::Templates::ThingsShow)

        expect(output).to include("stats: Record<string, number>")
        expect(output).not_to include("unknown")
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

  # Multi-root apps (a core root plus an overlay root, registered as
  # separate `discover` calls or `jbuilder_views` entries) reference
  # partials across roots exactly like Rails' view-path stack: the
  # template's own root is tried first, then every other registered root in
  # registration order.
  describe "multi-root partial resolution" do
    let(:core_root) { Dir.mktmpdir("typelizer-jbuilder-core-root") }
    let(:overlay_root) { Dir.mktmpdir("typelizer-jbuilder-overlay-root") }

    before { Typelizer::Jbuilder.reset! }

    after do
      Typelizer::Jbuilder.reset!
      FileUtils.rm_rf(core_root)
      FileUtils.rm_rf(overlay_root)
    end

    def write_template(root, relative_path, body)
      full = File.join(root, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
      full
    end

    def render_interface(klass)
      ctx = Typelizer::WriterContext.new(writer_name: nil)
      Typelizer::Renderer.call("interface.ts.erb", interface: ctx.interface_for(klass))
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

    it "resolves a partial that only exists under a sibling registered root, as a named import" do
      write_template(overlay_root, "widgets/_widget.json.jbuilder", <<~RUBY)
        json.id widget.id, typelize: "number"
      RUBY
      write_template(core_root, "dashboard/show.json.jbuilder", <<~RUBY)
        json.widget @widget, partial: "widgets/widget", as: :widget
      RUBY

      Typelizer::Jbuilder.discover(core_root)
      Typelizer::Jbuilder.discover(overlay_root)
      output = render_interface(Typelizer::Jbuilder::Templates::DashboardShow)

      expect(output).to include("widget: Widget;")
      expect(output).to include("import type {Widget}")
    end

    it "auto-registers a late-added cross-root partial under ITS root (root-relative name derivation)" do
      write_template(core_root, "dashboard/show.json.jbuilder", <<~RUBY)
        json.widget @widget, partial: "widgets/widget", as: :widget
      RUBY
      Typelizer::Jbuilder.discover(core_root)
      Typelizer::Jbuilder.discover(overlay_root) # empty at discovery time, root still tracked

      write_template(overlay_root, "widgets/_widget.json.jbuilder", <<~RUBY)
        json.id widget.id, typelize: "number"
      RUBY
      output = render_interface(Typelizer::Jbuilder::Templates::DashboardShow)

      # `Widget`, not a core-root-relative (or garbage) derivation — the
      # partial registered relative to the root it was found in.
      expect(output).to include("widget: Widget;")
      expect(Typelizer::Jbuilder::Templates::Widget._views_root).to eq(File.expand_path(overlay_root))
    end

    it "prefers the template's own root when the partial exists under both" do
      write_template(core_root, "widgets/_widget.json.jbuilder", <<~RUBY)
        typelize_as "CoreWidget"

        json.core true
      RUBY
      write_template(overlay_root, "widgets/_widget.json.jbuilder", <<~RUBY)
        typelize_as "OverlayWidget"

        json.overlay true
      RUBY
      write_template(core_root, "dashboard/show.json.jbuilder", <<~RUBY)
        json.widget @widget, partial: "widgets/widget", as: :widget
      RUBY

      Typelizer::Jbuilder.discover(core_root)
      Typelizer::Jbuilder.discover(overlay_root)
      output = render_interface(Typelizer::Jbuilder::Templates::DashboardShow)

      expect(output).to include("widget: CoreWidget;")
      expect(output).not_to include("OverlayWidget")
    end

    it "projects bare partial names onto the same relative directory under sibling roots" do
      write_template(overlay_root, "posts/_extra.json.jbuilder", <<~RUBY)
        json.bonus true
      RUBY
      write_template(core_root, "posts/show.json.jbuilder", <<~RUBY)
        json.partial! "extra"
        json.own true
      RUBY

      Typelizer::Jbuilder.discover(core_root)
      Typelizer::Jbuilder.discover(overlay_root)
      output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)

      expect(output).to include("bonus: boolean")
      expect(output).to include("own: boolean")
    end

    it "still warns when the partial is under no registered root" do
      write_template(core_root, "dashboard/show.json.jbuilder", <<~RUBY)
        json.partial! "missing/widget"
      RUBY

      logs = with_capture_logger do
        Typelizer::Jbuilder.discover(core_root)
        Typelizer::Jbuilder.discover(overlay_root)
        render_interface(Typelizer::Jbuilder::Templates::DashboardShow)
      end

      expect(logs).to include("missing/widget")
      expect(logs).to include("could not be resolved")
    end

    describe "view-path shadowing (same relative path across roots)" do
      it "lets the first root win instead of raising NameCollision" do
        write_template(core_root, "posts/show.json.jbuilder", <<~RUBY)
          json.core true
        RUBY
        write_template(overlay_root, "posts/show.json.jbuilder", <<~RUBY)
          json.overlay true
        RUBY

        expect {
          Typelizer::Jbuilder.discover(core_root)
          Typelizer::Jbuilder.discover(overlay_root)
        }.not_to raise_error

        output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
        # Rails renders the first view path's template; the shadowed file
        # must not produce a type (or abort the whole cycle).
        expect(output).to include("core: boolean")
        expect(output).not_to include("overlay")
      end

      it "resolves partial references to a shadowed path to the winning root's type" do
        write_template(core_root, "widgets/_widget.json.jbuilder", <<~RUBY)
          json.core true
        RUBY
        write_template(overlay_root, "widgets/_widget.json.jbuilder", <<~RUBY)
          json.overlay true
        RUBY
        write_template(overlay_root, "dash/show.json.jbuilder", <<~RUBY)
          json.widget @widget, partial: "widgets/widget", as: :widget
        RUBY

        Typelizer::Jbuilder.discover(core_root)
        Typelizer::Jbuilder.discover(overlay_root)
        output = render_interface(Typelizer::Jbuilder::Templates::DashShow)

        expect(output).to include("widget: Widget")
        expect(Typelizer::Jbuilder::Templates::Widget._views_root).to eq(File.expand_path(core_root))
      end

      it "still raises NameCollision for different relative paths claiming one name" do
        write_template(core_root, "aaa/thing.json.jbuilder", %(typelize_as "DupName"\n\njson.x 1\n))
        write_template(core_root, "bbb/thing.json.jbuilder", %(typelize_as "DupName"\n\njson.x 1\n))

        expect { Typelizer::Jbuilder.discover(core_root) }
          .to raise_error(Typelizer::Jbuilder::NameCollision)
      end

      it "keeps the first registration as the relative-slot winner across direct template calls" do
        first = write_template(core_root, "posts/show.json.jbuilder", "json.core true\n")
        write_template(overlay_root, "posts/show.json.jbuilder", "json.overlay true\n")

        core_klass = Typelizer::Jbuilder.template("posts/show.json.jbuilder", views_root: core_root)
        overlay_klass = Typelizer::Jbuilder.template(
          "posts/show.json.jbuilder", views_root: overlay_root, as: "OverlayPostsShow"
        )

        # The later registration must not steal the shadowing slot (Rails
        # view-path order: the FIRST root containing a relative path wins)...
        expect(overlay_klass).not_to be(core_klass)
        expect(Typelizer::Jbuilder.relative_registry.fetch("posts/show.json.jbuilder")).to be(core_klass)

        # ...so template_for keeps resolving through the slot to the first
        # root's class: directly for the winner's own absolute path, and via
        # shadowing for the same relative path under yet another root (which
        # has no absolute-registry entry of its own).
        expect(Typelizer::Jbuilder.template_for(File.expand_path(first), views_root: core_root))
          .to be(core_klass)

        third_root = Dir.mktmpdir("typelizer-jbuilder-third-root")
        begin
          shadowed = write_template(third_root, "posts/show.json.jbuilder", "json.third true\n")
          expect(Typelizer::Jbuilder.template_for(shadowed, views_root: third_root)).to be(core_klass)
        ensure
          FileUtils.rm_rf(third_root)
        end
      end
    end

    describe "explicit re-registration" do
      it "removes the stale constant when a template is re-registered under a new name" do
        path = write_template(core_root, "reports/summary.json.jbuilder", %(json.ok true\n))

        Typelizer::Jbuilder.template(path, views_root: core_root, as: "OldName")
        Typelizer::Jbuilder.template(path, views_root: core_root, as: "NewName")

        expect(Typelizer::Jbuilder::Templates.constants).to include(:NewName)
        expect(Typelizer::Jbuilder::Templates.constants).not_to include(:OldName)
        expect(Typelizer.base_classes).not_to include("Typelizer::Jbuilder::Templates::OldName")
      end
    end
  end
end
