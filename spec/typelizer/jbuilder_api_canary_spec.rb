# frozen_string_literal: true

require "jbuilder"
require "jbuilder/jbuilder_template"

# CI canary for the warn-on-drop invariant.
#
# The walker treats every `json.<name> ...` call as a property UNLESS
# `extract_one` has an explicit `when` arm for that method name. jbuilder's
# own DSL methods (`merge!`, `child!`, `nil!`, `attributes!`, …) are NOT
# properties — left to the `else` arm they emit a bogus property literally
# named after the method (e.g. a `merge!:` key), or silently distort the
# type. The whole plugin rests on the rule that no type-distorting jbuilder
# API is handled silently: each must be typed or warn+skip.
#
# This spec asserts that rule holds against jbuilder's ACTUAL public template
# API at test time. When a future jbuilder release adds a DSL method, the
# diff goes non-empty and CI fails here — forcing a conscious decision about
# how the walker should treat it — instead of the method silently slipping
# into the `else` arm and shipping broken types.
#
# The "dispatched" set is read straight from the walker source with Prism (no
# hand-maintained duplicate to drift): it parses `extract_one`'s `case`, so
# an accidentally-removed arm is caught too.
RSpec.describe "Jbuilder API canary" do
  let(:plugin) { Typelizer::SerializerPlugins::Jbuilder }

  # jbuilder's full public template DSL surface. Jbuilder descends straight
  # from BasicObject (not Object — so method_missing can catch every key),
  # so subtracting BasicObject's handful of public methods (`==`, `!`,
  # `__send__`, …) strips the root noise while keeping every DSL method.
  # This deliberately does NOT use `public_instance_methods(false)`: that
  # would miss a method a future jbuilder contributes via an included module,
  # which is exactly the kind of release this canary must survive. The
  # property path itself (`method_missing`) is private in both jbuilder and
  # typelizer's prepended `SetExt` (which the render-safety specs enforce),
  # but it is subtracted explicitly anyway: whether it leaks into the public
  # surface depends on which patches happen to be prepended when this file
  # runs, and dispatch-wise it IS `set!` — already an arm.
  let(:jbuilder_dsl_methods) do
    ((Jbuilder.public_instance_methods + JbuilderTemplate.public_instance_methods) -
      BasicObject.public_instance_methods -
      [:method_missing, :respond_to_missing?]).uniq
  end

  # The method names `extract_one` dispatches on, parsed from the walker.
  let(:dispatched_calls) do
    walker = plugin.activate_walker! # loads Prism and the Walker constant
    source = File.read(walker_source_path)
    case_node = extract_one_case(Prism.parse(source).value)
    raise "could not locate extract_one's `case` in #{walker_source_path}" unless case_node

    calls = case_node.conditions.flat_map { |when_node| when_arm_symbols(when_node, walker) }
    # Sanity floor: if a refactor reshapes the dispatch so the parse yields
    # almost nothing, fail loudly rather than pass a neutered canary.
    raise "extract_one parse yielded only #{calls.size} arms — refactor likely broke the canary" if calls.size < 10

    calls
  end

  # Dispatch arms intentionally kept for methods OUTSIDE jbuilder's public
  # surface. Currently none: a name jbuilder doesn't define routes through
  # `method_missing`/`set!` at render time — i.e. it IS a property — so a
  # special arm for it would type something the runtime doesn't do. Add an
  # entry here only with a written justification.
  let(:dispatch_allowlist) { [] }

  it "dispatches on every public jbuilder DSL method" do
    unaccounted = jbuilder_dsl_methods - dispatched_calls

    expect(unaccounted).to be_empty, <<~MSG
      jbuilder #{Jbuilder::VERSION} exposes DSL method(s) the walker does not
      dispatch on: #{unaccounted.inspect}

      Each falls through extract_one's `else` arm and is emitted as a bogus
      property named after the method (e.g. `#{unaccounted.first}:`), breaking
      the generated types. Add an explicit `when` arm in
      lib/typelizer/serializer_plugins/jbuilder/walker.rb — type it, or
      warn+skip via `warn_skipped` / `log_warning` — then add a spec.
      This is the warn-on-drop invariant: no jbuilder API is handled silently.
    MSG
  end

  it "dispatches on nothing beyond jbuilder's public DSL surface" do
    phantom = dispatched_calls.uniq - jbuilder_dsl_methods - dispatch_allowlist

    expect(phantom).to be_empty, <<~MSG
      The walker dispatches on method(s) jbuilder #{Jbuilder::VERSION} does not
      expose: #{phantom.inspect}

      At render time jbuilder routes an undefined name through
      `method_missing`/`set!` — it renders as a plain JSON key — so a special
      arm mis-models the runtime (a dead arm at best, a silently dropped
      property at worst). Remove the arm from extract_one, or add the name to
      `dispatch_allowlist` with a justification.
    MSG
  end

  private

  def walker_source_path
    File.expand_path("../../lib/typelizer/serializer_plugins/jbuilder/walker.rb", __dir__)
  end

  # Depth-first search for the `case` inside `def extract_one`.
  def extract_one_case(root)
    def_node = find_node(root) { |n| n.is_a?(Prism::DefNode) && n.name == :extract_one }
    return nil unless def_node

    find_node(def_node) { |n| n.is_a?(Prism::CaseNode) }
  end

  def find_node(node, &block)
    return node if block.call(node)

    node.compact_child_nodes.each do |child|
      found = find_node(child, &block)
      return found if found
    end
    nil
  end

  # A `when` condition is either a literal symbol (`when :merge!`) or a splat
  # of a constant array (`when *PASSTHROUGH_CALLS`) — resolve both.
  def when_arm_symbols(when_node, walker)
    when_node.conditions.flat_map do |cond|
      case cond
      when Prism::SymbolNode
        cond.unescaped.to_sym
      when Prism::SplatNode
        const = cond.expression
        const.is_a?(Prism::ConstantReadNode) ? walker.const_get(const.name) : []
      else
        []
      end
    end
  end
end
