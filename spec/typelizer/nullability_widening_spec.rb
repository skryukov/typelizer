# frozen_string_literal: true

# Model inference must WIDEN, never narrow, plugin-provided nullability and
# optionality. The jbuilder walker proves nil renders (nullable) and omitted
# keys (optional) from template source; a NOT NULL column with the same name
# must not clobber that evidence. Props arriving WITHOUT the flag keep the
# plain column-driven assignment — so a plugin that never pre-sets the flag
# (the common column-backed attribute) is unaffected. A plugin that DOES
# pre-set `nullable: true`/optional on a NOT NULL column (e.g. an Alba custom
# type with `auto_convert: false`) now keeps it instead of being narrowed;
# that behavior change and its one-time file rewrite are noted in the
# CHANGELOG.
RSpec.describe "model inference nullability widening" do
  let(:views_root) { Dir.mktmpdir("typelizer-nullability-widening") }

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

  def render_interface(klass)
    ctx = Typelizer::WriterContext.new(writer_name: nil)
    Typelizer::Renderer.call("interface.ts.erb", interface: ctx.interface_for(klass))
  end

  # users.name is NOT NULL; each template demonstrably renders nil.
  it "keeps walker nullability when a ternary nil arm meets a NOT NULL column" do
    write_template("users/show.json.jbuilder", <<~RUBY)
      typelize_from User
      json.name @full ? @user.name : nil
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
    expect(output).to include("name: string | null")
  end

  it "keeps walker nullability when a nil re-set fold meets a NOT NULL column" do
    write_template("users/show.json.jbuilder", <<~RUBY)
      typelize_from User
      json.name nil
      json.name @user.name if @full
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
    expect(output).to include("name: string | null")
  end

  # posts.user_id is NOT NULL, so belongs_to inference (:database strategy)
  # says non-nullable — but the template conditionally re-sets `user` to nil.
  it "keeps walker nullability on an association-named prop (belongs_to arm)" do
    write_template("posts/show.json.jbuilder", <<~RUBY)
      typelize_from Post
      json.user do
        json.name "x"
      end
      json.user nil if @anon
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to match(/user: \{[\s\S]*?\} \| null;/)
  end

  # Conditional statement → walker proves the key can be absent; under
  # :nullable_and_optional the NOT NULL column must not erase optional.
  it "keeps walker optionality under null_strategy :nullable_and_optional" do
    snapshot = TypelizerConfigurationState.snapshot
    begin
      Typelizer.configure { |c| c.null_strategy = :nullable_and_optional }
      write_template("users/show.json.jbuilder", <<~RUBY)
        typelize_from User
        json.name @user.name if @admin
      RUBY
      Typelizer::Jbuilder.discover(views_root)

      output = render_interface(Typelizer::Jbuilder::Templates::UsersShow)
      expect(output).to include("name?:")
    ensure
      TypelizerConfigurationState.restore(snapshot)
    end
  end

  # Control: a prop arriving WITHOUT the flag keeps today's column-driven
  # assignment — an unconditional read off a nullable column still widens.
  it "still assigns column nullability when the plugin provided none" do
    write_template("posts/show.json.jbuilder", <<~RUBY)
      typelize_from Post
      json.extract! @post, :title
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to include("title: string | null")
  end
end
