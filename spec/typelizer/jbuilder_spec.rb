# frozen_string_literal: true

RSpec.describe Typelizer::Jbuilder do
  describe ".derive_type_name (via public template registration)" do
    let(:views_root) { Dir.mktmpdir("typelizer-jbuilder-spec") }

    after do
      # `template` mutates `Templates::Name` classes by name, and spec type
      # names (`Post`, `User`, …) collide with the spec app's discovered
      # templates. Reset the whole registry and rehydrate from the spec app
      # so other specs still see the shared fixtures.
      Typelizer::Jbuilder.reset!
      Typelizer::Jbuilder.discover(Rails.root.join("app/views").to_s)
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

    after do
      Typelizer::Jbuilder.reset!
      Typelizer::Jbuilder.discover(Rails.root.join("app/views").to_s)
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

    it "falls back to inline shape when the block contains anything other than `partial!`" do
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

      expect(output).to include("course: {")
      expect(output).to include("note: string")
    end
  end
end
