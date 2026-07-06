# frozen_string_literal: true

# A top-level `json.partial!` MERGES the partial's properties into the host.
# Those properties are the FINAL output of the partial's own interface,
# inferred against the PARTIAL's model — the host must not re-infer them
# against its OWN model (repaint) nor mutate the shared, memoized objects
# (which corrupts the partial's own interface and makes output order-dependent).
RSpec.describe "Jbuilder cross-model partial merge" do
  let(:views_root) { Dir.mktmpdir("typelizer-cross-model-partial") }

  before(:all) do
    conn = ActiveRecord::Base.connection
    conn.create_table(:xmerge_users, force: true) { |t| t.string :status, null: false }
    conn.create_table(:xmerge_posts, force: true) { |t| t.integer :status, null: true }

    Object.const_set(:XmergeUser, Class.new(ActiveRecord::Base) { self.table_name = "xmerge_users" })
    Object.const_set(:XmergePost, Class.new(ActiveRecord::Base) do
      self.table_name = "xmerge_posts"
      enum status: {draft: 0, live: 1}
    end)
    XmergeUser.reset_column_information
    XmergePost.reset_column_information
  end

  after(:all) do
    conn = ActiveRecord::Base.connection
    conn.drop_table(:xmerge_users, if_exists: true)
    conn.drop_table(:xmerge_posts, if_exists: true)
    Object.send(:remove_const, :XmergeUser) if Object.const_defined?(:XmergeUser)
    Object.send(:remove_const, :XmergePost) if Object.const_defined?(:XmergePost)
  end

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

  before do
    write_template("xmerge_users/_xmerge_user.json.jbuilder", <<~RUBY)
      typelize_from XmergeUser

      json.extract! xmerge_user, :status
    RUBY

    write_template("xmerge_posts/show.json.jbuilder", <<~RUBY)
      typelize_from XmergePost

      json.partial! "xmerge_users/xmerge_user"
    RUBY

    Typelizer::Jbuilder.discover(views_root)
  end

  it "keeps the merged prop typed by the PARTIAL's model, not repainted by the host's" do
    host = render_interface(Typelizer::Jbuilder::Templates::XmergePostsShow)

    # XmergeUser#status is a NOT NULL string; the host's XmergePost#status is
    # a nullable integer enum. The merged `status` must stay the partial's
    # `string`, never the host's enum or `| null`.
    expect(host).to include("status: string")
    expect(host).not_to include("XmergePostStatus")
    expect(host).not_to include("status: string | null")
  end

  it "does not corrupt the partial's own interface when the host is rendered first (order-independence)" do
    # Render the host (which merges + would previously mutate the shared
    # objects), then the partial — its own `status: string` must survive.
    render_interface(Typelizer::Jbuilder::Templates::XmergePostsShow)
    partial = render_interface(Typelizer::Jbuilder::Templates::XmergeUser)

    expect(partial).to include("status: string")
    expect(partial).not_to include("XmergePostStatus")
    expect(partial).not_to include("status: string | null")
  end
end
