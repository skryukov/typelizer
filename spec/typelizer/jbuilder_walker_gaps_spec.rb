# frozen_string_literal: true

# Coverage-gap cases surfaced by the dead-code audit (union coverage of the
# fuzz campaign + real-world corpus + this suite): reachable walker arms no
# instrument exercised. Each example pins one previously-untested line.
RSpec.describe "Jbuilder walker coverage gaps" do
  let(:views_root) { Dir.mktmpdir("typelizer-walker-gaps") }

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
    Typelizer::Renderer.call("interface.ts.erb", interface: ctx.interface_for(klass))
  end

  def capture_warnings
    io = StringIO.new
    original = Typelizer.logger
    Typelizer.logger = Logger.new(io)
    yield
    io.string
  ensure
    Typelizer.logger = original
  end

  it "accepts a Symbol argument to typelize_as" do
    write_template("posts/show.json.jbuilder", <<~RUBY)
      typelize_as :CustomShow

      json.id 1
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    expect(Typelizer::Jbuilder::Templates.const_defined?(:CustomShow)).to be(true)
  end

  it "parses a namespaced constant path in typelize_from" do
    path = write_template("posts/show.json.jbuilder", <<~RUBY)
      typelize_from Shop::Product

      json.id 1
    RUBY
    walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!

    expect(walker.metadata_for(path)[:model]).to eq("Shop::Product")
  end

  it "widens to | null when a conditional value has an EMPTY branch arm" do
    # The empty then-arm evaluates to nil at render — the type must say so.
    write_template("posts/show.json.jbuilder", <<~RUBY)
      json.total(if @flag
      else
        5
      end)
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to include("total: number | null")
  end

  it "types `expr || nil` from the name hint with | null (no null | null)" do
    write_template("posts/show.json.jbuilder", <<~RUBY)
      json.total @count || nil
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to include("total: number | null")
    expect(output).not_to include("null | null")
  end

  it "unions boolean when a literal true guards the right operand of &&" do
    write_template("posts/show.json.jbuilder", <<~RUBY)
      json.total true && @amount
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to match(/total: .*boolean/)
  end

  it "warns on a blockless attribute-form array! inside a block" do
    logs = capture_warnings do
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.wrapper do
          json.array! @people, :total
        end
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    end

    expect(logs).to include("emits its attributes as an object shape")
  end

  it "drops a conditional root attribute-form array! in an object template (warned)" do
    output = nil
    logs = capture_warnings do
      write_template("posts/show.json.jbuilder", <<~RUBY)
        json.name "x"
        if @admin
          json.array! @people, :total
        end
      RUBY
      Typelizer::Jbuilder.discover(views_root)
      output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    end

    expect(output).to include("name: string")
    expect(output).not_to include("total")
    expect(logs).to match(/WARN/)
  end

  it "finalizes ArrayOf elements inside merged partial properties" do
    # The partial's `items` is a collection block whose per-element scope is
    # a child! array — Array<Array<{a}>> — and the merge deep-copy must
    # recurse through the ArrayOf wrapper.
    write_template("shared/_rows.json.jbuilder", <<~RUBY)
      json.items @xs do |x|
        json.child! do
          json.total 1
        end
      end
    RUBY
    write_template("posts/show.json.jbuilder", <<~RUBY)
      json.partial! "shared/rows", xs: []
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    expect(output).to match(/items: Array<Array</)
  end

  it "keeps a scalar union member when a conditional child! block concatenates" do
    # if/else makes `k` a scalar|array union; the trailing conditional
    # child!-block CONCATs onto the array member while the scalar member
    # SURVIVES (it renders in the states where the block doesn't run).
    write_template("posts/show.json.jbuilder", <<~RUBY)
      if @a
        json.k 1
      else
        json.k do
          json.child! do
            json.left "x"
          end
        end
      end
      if @b
        json.k do
          json.child! do
            json.right "y"
          end
        end
      end
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    output = render_interface(Typelizer::Jbuilder::Templates::PostsShow)
    # scalar member survives alongside the concatenated element-member union
    expect(output).to match(/k: number \| Array</)
    expect(output).to match(/left: string/)
    expect(output).to match(/right: string/)
  end
end
