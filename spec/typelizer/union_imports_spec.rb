# frozen_string_literal: true

# Import (and enum) collection must recurse structurally into the walker
# fold's union members and ArrayOf elements: an Interface referenced inside
# a union-member Shape must be imported (otherwise TS2304 in the generated
# file), and a Shape body must never be string-tokenized (which leaked
# rendered fragments like `User;` into the import list).
RSpec.describe "imports through fold-produced unions" do
  let(:views_root) { Dir.mktmpdir("typelizer-union-imports") }

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

  def interface_for(klass)
    Typelizer::WriterContext.new(writer_name: nil).interface_for(klass)
  end

  it "imports an interface referenced inside a union-member shape" do
    write_template("teachers/_teacher.json.jbuilder", <<~RUBY)
      json.id teacher.id, typelize: "number"
    RUBY
    write_template("things/show.json.jbuilder", <<~RUBY)
      json.course do
        json.teacher @teacher, partial: "teachers/teacher", as: :teacher
      end
      json.course "closed" if @closed
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    interface = interface_for(Typelizer::Jbuilder::Templates::ThingsShow)
    output = Typelizer::Renderer.call("interface.ts.erb", interface: interface)

    expect(interface.imports).to eq(["Teacher"])
    expect(output).to include("import type {Teacher} from '@/types'")
    expect(output).to include("teacher: Teacher;")
  end

  it "imports an interface referenced inside an ArrayOf element shape without tokenizing the rendered body" do
    write_template("users/_user.json.jbuilder", <<~RUBY)
      json.id user.id, typelize: "number"
    RUBY
    write_template("things/show.json.jbuilder", <<~RUBY)
      json.items @items do |i|
        json.child! do
          json.author @a, partial: "users/user", as: :user
        end
      end
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    interface = interface_for(Typelizer::Jbuilder::Templates::ThingsShow)
    output = Typelizer::Renderer.call("interface.ts.erb", interface: interface)

    expect(interface.imports).to eq(["User"])
    expect(output).to include("import type {User} from '@/types'")
    # No leaked `Name;` tokens from a rendered Shape body.
    expect(interface.imports.grep(/;/)).to be_empty
    import_line = output.lines.grep(/\Aimport type \{/).join
    expect(import_line).not_to include(";")
  end

  it "collects enum types declared inside a union-member shape" do
    write_template("things/show.json.jbuilder", <<~RUBY)
      typelize_from User
      json.author do
        json.extract! @user, :role
      end
      json.author "anon" if @hide
    RUBY
    Typelizer::Jbuilder.discover(views_root)

    interface = interface_for(Typelizer::Jbuilder::Templates::ThingsShow)
    expect(interface.enum_types.map(&:enum_type_name)).to include("UserRole")
  end
end
