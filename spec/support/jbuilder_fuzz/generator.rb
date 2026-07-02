# frozen_string_literal: true

module JbuilderFuzz
  # A generated template plus everything needed to render it with real
  # jbuilder: the fixed data ivars and the enumerated render states (every
  # combination of the boolean "dimensions" — conditional flags and
  # nil-or-present safe-navigation receivers).
  GeneratedTemplate = Struct.new(:seed, :source, :base_ivars, :states, keyword_init: true)

  # Deterministic template generator: all randomness flows from a single
  # Random.new(seed), so a seed is a complete reproduction recipe.
  #
  # Grammar v1 — only constructs the walker supports with EXACT (non-heuristic)
  # semantics are allowed to produce checkable types; name-hint-driven typing
  # is only exercised with runtime values that MATCH the hint, so a checker
  # rejection is always a genuine soundness divergence, never a by-design
  # heuristic false alarm:
  #
  #   - scalar props from literals (string/int/float/true/false/nil)
  #   - ivar values (type-stable across states)
  #   - conditionals: if / if-else / unless(-else) / trailing modifiers
  #     (up to 3 flag ivars; all 2^k combinations become render states)
  #   - duplicate-key re-sets at one level (scalar/scalar, scalar/nil,
  #     block/scalar, block/block — the merge fold's hot zone)
  #   - object blocks (depth <= 3) incl. |b| / `it` / `_1` builder rebinding
  #   - array blocks over generator-controlled collections (element reads)
  #   - json.extract! on Structs (non-hint attrs => `unknown`, hint attrs
  #     with matching values), optionally followed by literal re-sets
  #   - safe navigation (@maybe&.field) and .try(:field) with nil states
  #   - ternaries incl. nil arms; parenthesized values (space-call form)
  #   - root arrays (json.array! @xs do |x| ... end)
  class Generator
    MAX_DIMS = 3    # flags + maybes; render states = 2^dims <= 8
    MAX_STMTS = 12  # cap on emitted json-write statements
    MAX_DEPTH = 3   # block nesting

    # Name-hint vocabulary (mirrors Walker::NAME_HINT) with the type each
    # hint implies. Generated runtime values for these names always match.
    HINT_NAMES = {
      "created_at" => "string",
      "updated_at" => "string",
      "published_on" => "string",
      "user_id" => "number",
      "item_id" => "number",
      "items_count" => "number",
      "total" => "number",
      "page" => "number",
      "is_active" => "boolean",
      "has_badge" => "boolean",
      "can_edit" => "boolean"
    }.freeze

    TYPES = %w[string number boolean].freeze

    def initialize(seed)
      @seed = seed
      @rng = Random.new(seed)
      @flags = []   # flag ivar names (String, sans @)
      @maybes = []  # {ivar:, field:, value:, object:}
      @data = {}    # ivar name (String, sans @) => fixed runtime value
      @seq = 0
      @stmts_left = MAX_STMTS
    end

    def generate
      lines = (@rng.rand < 0.15) ? gen_root_array : gen_top_level
      GeneratedTemplate.new(
        seed: @seed,
        source: lines.join("\n") + "\n",
        base_ivars: @data.dup,
        states: build_states
      )
    end

    private

    # ---- render-state enumeration -------------------------------------

    def build_states
      dims = @flags.map { |f| [:flag, f] } + @maybes.map { |m| [:maybe, m] }
      return [{desc: "(single state)", ivars: {}}] if dims.empty?

      combos = [[]]
      dims.each { |dim| combos = combos.flat_map { |c| [c + [[dim, true]], c + [[dim, false]]] } }
      combos.map do |assignment|
        ivars = {}
        descs = []
        assignment.each do |(kind, obj), on|
          case kind
          when :flag
            ivars[obj] = on
            descs << "@#{obj}=#{on}"
          when :maybe
            ivars[obj[:ivar]] = on ? obj[:object] : nil
            descs << "@#{obj[:ivar]}=#{on ? "present" : "nil"}"
          end
        end
        {desc: descs.join(" "), ivars: ivars}
      end
    end

    # ---- dimension / ivar allocation ----------------------------------

    def dims_used
      @flags.size + @maybes.size
    end

    def acquire_flag
      if @flags.any? && (dims_used >= MAX_DIMS || @rng.rand < 0.5)
        @flags[@rng.rand(@flags.size)]
      elsif dims_used < MAX_DIMS
        flag = "flag#{@flags.size + 1}"
        @flags << flag
        flag
      end
    end

    # A maybe receiver whose field value matches `type`. Creates a new
    # dimension when the budget allows, else reuses a type-compatible one.
    def acquire_maybe(field, type)
      if dims_used < MAX_DIMS
        value = sample_value(type)
        maybe = {
          ivar: "m#{@maybes.size + 1}",
          field: field,
          value: value,
          object: Struct.new(field.to_sym).new(value)
        }
        @maybes << maybe
        maybe
      else
        @maybes.find { |m| runtime_type(m[:value]) == type }
      end
    end

    def data_ivar(value)
      name = "d#{@data.size + 1}"
      @data[name] = value
      name
    end

    def collection_ivar(elements)
      name = "c#{@data.size + 1}"
      @data[name] = elements
      name
    end

    # ---- names and values ----------------------------------------------

    def fresh_name(used, hint_prob: 0.35)
      if @rng.rand < hint_prob
        candidates = HINT_NAMES.keys - used.to_a
        unless candidates.empty?
          name = candidates[@rng.rand(candidates.size)]
          used << name
          return name
        end
      end
      @seq += 1
      name = "k#{@seq}"
      used << name
      name
    end

    def sample_value(type)
      case type
      when "string" then "s#{@rng.rand(100)}"
      when "number" then (@rng.rand < 0.3) ? (@rng.rand(100) + 0.5) : @rng.rand(100)
      when "boolean" then @rng.rand < 0.5
      end
    end

    def runtime_type(value)
      case value
      when String then "string"
      when Numeric then "number"
      when true, false then "boolean"
      end
    end

    def lit(type)
      case type
      when "string" then sample_value("string").inspect
      else sample_value(type).to_s
      end
    end

    # A value expression for a property named `name`. Hint-named props only
    # ever see runtime values matching their hint type (or nil, whose
    # handling is exactly what the fuzzer probes).
    def value_expr(name, element: nil, allow_nil: true)
      type = HINT_NAMES[name] || TYPES[@rng.rand(TYPES.size)]
      pool = [:literal] * 6 + [:ivar] * 3 + [:safe_nav] * 3 + [:try] * 2 +
        [:ternary] * 5 + [:parens_ternary] * 2
      pool += [:nil_lit] * 2 if allow_nil
      pool += [:element] * 8 if element

      case pool[@rng.rand(pool.size)]
      when :literal then lit(type)
      when :nil_lit then "nil"
      when :ivar then "@#{data_ivar(sample_value(type))}"
      when :element then element_read(name, type, element)
      when :safe_nav
        maybe = acquire_maybe(name, type)
        maybe ? "@#{maybe[:ivar]}&.#{maybe[:field]}" : "@#{data_ivar(sample_value(type))}"
      when :try
        maybe = acquire_maybe(name, type)
        maybe ? "@#{maybe[:ivar]}.try(:#{maybe[:field]})" : lit(type)
      when :ternary then ternary_expr(type)
      when :parens_ternary then "(#{ternary_expr(type)})"
      end
    end

    def element_read(name, type, element)
      element[:fields][name.to_sym] ||= type
      # Reuse the registered type if the field already exists (type-stable).
      "#{element[:var]}[:#{name}]"
    end

    def ternary_expr(type)
      flag = acquire_flag
      return lit(type) unless flag

      arm1 = (@rng.rand < 0.30) ? "nil" : lit(type)
      # Never both arms nil: an always-nil value under a hint-named prop
      # would probe the heuristic, not the walker's nil handling.
      arm2 = (arm1 != "nil" && @rng.rand < 0.45) ? "nil" : lit(type)
      "@#{flag} ? #{arm1} : #{arm2}"
    end

    def write_line(builder, name, expr)
      @stmts_left -= 1
      (@rng.rand < 0.1) ? "#{builder}.#{name}(#{expr})" : "#{builder}.#{name} #{expr}"
    end

    # ---- statement units -----------------------------------------------

    UNIT_WEIGHTS = {
      simple: 4, conditional: 5, reset: 5, object_block: 3, array_block: 2, extract: 2
    }.freeze

    def gen_top_level
      used = Set.new
      lines = []
      (2 + @rng.rand(4)).times do
        lines.concat(gen_unit(depth: 0, builder: "json", used: used, element: nil))
      end
      lines << write_line("json", fresh_name(used), lit("string")) if lines.empty?
      lines
    end

    def gen_unit(depth:, builder:, used:, element:, allow_blocks: true)
      return [] if @stmts_left <= 0

      pool = UNIT_WEIGHTS.flat_map { |kind, weight| [kind] * weight }
      pool -= [:object_block, :array_block] if depth >= MAX_DEPTH || !allow_blocks
      pool -= [:extract] if element

      case pool[@rng.rand(pool.size)]
      when :simple then [simple_line(builder, used, element)]
      when :conditional then conditional_unit(depth: depth, builder: builder, used: used, element: element)
      when :reset then reset_cluster(depth: depth, builder: builder, used: used, element: element)
      when :object_block then object_block(depth: depth, builder: builder, used: used, element: element)
      when :array_block then array_block(depth: depth, builder: builder, used: used)
      when :extract then extract_unit(builder, used)
      end
    end

    def simple_line(builder, used, element)
      name = fresh_name(used)
      write_line(builder, name, value_expr(name, element: element))
    end

    def gen_body(depth:, builder:, used:, element:)
      lines = []
      (1 + @rng.rand(2)).times do
        lines.concat(gen_unit(depth: depth, builder: builder, used: used, element: element,
          allow_blocks: depth < MAX_DEPTH))
      end
      lines << simple_line(builder, used, element) if lines.empty?
      lines
    end

    def conditional_unit(depth:, builder:, used:, element:)
      flag = acquire_flag
      return [simple_line(builder, used, element)] unless flag

      form = pick([:modifier, :modifier_unless, :if, :if_else, :unless_else, :if_else_same_key, :if_else_same_key])
      case form
      when :modifier
        name = fresh_name(used)
        [write_line(builder, name, value_expr(name, element: element)) + " if @#{flag}"]
      when :modifier_unless
        name = fresh_name(used)
        [write_line(builder, name, value_expr(name, element: element)) + " unless @#{flag}"]
      when :if
        ["if @#{flag}", *indent(gen_body(depth: depth, builder: builder, used: used, element: element)), "end"]
      when :if_else
        b1 = gen_body(depth: depth, builder: builder, used: used, element: element)
        b2 = gen_body(depth: depth, builder: builder, used: used, element: element)
        ["if @#{flag}", *indent(b1), "else", *indent(b2), "end"]
      when :unless_else
        b1 = gen_body(depth: depth, builder: builder, used: used, element: element)
        b2 = gen_body(depth: depth, builder: builder, used: used, element: element)
        ["unless @#{flag}", *indent(b1), "else", *indent(b2), "end"]
      when :if_else_same_key
        # The merge_branches hot zone: the SAME key written in both branches,
        # possibly with different value types.
        name = fresh_name(used)
        line1 = write_line(builder, name, value_expr(name, element: element))
        line2 = write_line(builder, name, value_expr(name, element: element))
        ["if @#{flag}", *indent([line1]), "else", *indent([line2]), "end"]
      end
    end

    # Multiple writes to ONE key in statement order — jbuilder re-set
    # semantics vs the walker's merge_reset fold. An object block (jbuilder's
    # `_merge_block` path) may only appear in the LEADING run of the cluster:
    # merging a block into an already-set scalar/array raises at render time
    # in real jbuilder (NullError on nil, NoMethodError/MergeError otherwise),
    # so such a sequence is a template bug, not a typing divergence. Scalars,
    # nil, and value-carrying array blocks go through `_set_value` (replace)
    # and are safe in any position.
    def reset_cluster(depth:, builder:, used:, element:)
      name = fresh_name(used, hint_prob: 0.2)
      lines = []
      only_oblocks_so_far = true
      writes = 2 + ((@rng.rand < 0.35) ? 1 : 0)
      writes.times do |i|
        break if @stmts_left <= 0

        kinds = [:scalar] * 5 + [:nil] * 2
        kinds += [:oblock] * 3 if only_oblocks_so_far && depth < MAX_DEPTH
        kinds += [:ablock] * 2 if depth < MAX_DEPTH
        kind = kinds[@rng.rand(kinds.size)]
        flag = (@rng.rand < 0.6 && (i > 0 || @rng.rand < 0.5)) ? acquire_flag : nil

        case kind
        when :scalar
          only_oblocks_so_far = false
          line = write_line(builder, name, value_expr(name, element: element))
          line += " if @#{flag}" if flag
          lines << line
        when :nil
          only_oblocks_so_far = false
          line = write_line(builder, name, "nil")
          line += " if @#{flag}" if flag
          lines << line
        when :oblock
          block = object_block(depth: depth, builder: builder, used: Set.new, element: element,
            name: name, allow_alias: false)
          lines.concat(flag ? wrap_if(block, flag) : block)
        when :ablock
          only_oblocks_so_far = false
          block = array_block(depth: depth, builder: builder, used: Set.new, name: name)
          lines.concat(flag ? wrap_if(block, flag) : block)
        end
      end
      lines
    end

    def object_block(depth:, builder:, used:, element:, name: nil, allow_alias: true)
      name ||= fresh_name(used, hint_prob: 0.15)
      @stmts_left -= 1
      style = allow_alias ? pick_weighted(plain: 6, param: 2, it: 1, numbered: 1) : :plain
      inner_used = Set.new

      case style
      when :plain
        body = gen_body(depth: depth + 1, builder: "json", used: inner_used, element: element)
        ["#{builder}.#{name} do", *indent(body), "end"]
      when :param
        @seq += 1
        param = "b#{@seq}"
        body = gen_body(depth: depth + 1, builder: param, used: inner_used, element: element)
        ["#{builder}.#{name} do |#{param}|", *indent(body), "end"]
      else
        # `it`/`_1` rebinds per-block, so keep these bodies free of nested
        # blocks (a nested paramless block would silently rebind them).
        inner_builder = (style == :it) ? "it" : "_1"
        body = (1 + @rng.rand(2)).times.map { simple_line(inner_builder, inner_used, element) }
        ["#{builder}.#{name} do", *indent(body), "end"]
      end
    end

    def array_block(depth:, builder:, used:, name: nil)
      name ||= fresh_name(used, hint_prob: 0.1)
      @stmts_left -= 1
      @seq += 1
      param = "e#{@seq}"
      element = {var: param, fields: {}}
      body = gen_body(depth: depth + 1, builder: "json", used: Set.new, element: element)
      elements = Array.new(1 + @rng.rand(2)) do
        element[:fields].transform_values { |type| sample_value(type) }
      end
      collection = collection_ivar(elements)
      ["#{builder}.#{name} @#{collection} do |#{param}|", *indent(body), "end"]
    end

    def extract_unit(builder, used)
      attrs = []
      (1 + @rng.rand(3)).times do
        if @rng.rand < 0.3
          candidates = HINT_NAMES.keys - used.to_a - attrs
          attrs << candidates[@rng.rand(candidates.size)] unless candidates.empty?
        else
          @seq += 1
          attrs << "zz#{@seq}"
        end
      end
      attrs.uniq!
      return [simple_line(builder, used, nil)] if attrs.empty?

      attrs.each { |a| used << a }
      values = attrs.map { |a| sample_value(HINT_NAMES[a] || TYPES[@rng.rand(TYPES.size)]) }
      struct_ivar = "s#{@data.size + 1}"
      @data[struct_ivar] = Struct.new(*attrs.map(&:to_sym)).new(*values)
      @stmts_left -= 1
      lines = ["#{builder}.extract! @#{struct_ivar}, #{attrs.map { |a| ":#{a}" }.join(", ")}"]

      # Literal re-set after extract!: the unknown-member union hot zone.
      if @rng.rand < 0.45 && @stmts_left > 0
        attr = attrs[@rng.rand(attrs.size)]
        line = write_line(builder, attr, lit(TYPES[@rng.rand(TYPES.size)]))
        flag = (@rng.rand < 0.7) ? acquire_flag : nil
        line += " if @#{flag}" if flag
        lines << line
      end
      lines
    end

    def gen_root_array
      @seq += 1
      param = "e#{@seq}"
      element = {var: param, fields: {}}
      used = Set.new
      body = []
      (1 + @rng.rand(3)).times do
        body.concat(gen_unit(depth: 1, builder: "json", used: used, element: element))
      end
      body << simple_line("json", used, element) if body.empty?
      elements = Array.new(1 + @rng.rand(2)) do
        element[:fields].transform_values { |type| sample_value(type) }
      end
      collection = collection_ivar(elements)
      ["json.array! @#{collection} do |#{param}|", *indent(body), "end"]
    end

    # ---- helpers ---------------------------------------------------------

    def pick(options)
      options[@rng.rand(options.size)]
    end

    def pick_weighted(**weights)
      pool = weights.flat_map { |kind, weight| [kind] * weight }
      pool[@rng.rand(pool.size)]
    end

    def indent(lines)
      lines.map { |l| "  #{l}" }
    end

    def wrap_if(lines, flag)
      ["if @#{flag}", *indent(lines), "end"]
    end
  end
end
