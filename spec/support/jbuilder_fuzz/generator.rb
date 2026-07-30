# frozen_string_literal: true

module JbuilderFuzz
  # A generated template plus everything needed to render it with real
  # jbuilder: the fixed data ivars and the enumerated render states (every
  # combination of the boolean "dimensions" — conditional flags and
  # nil-or-present safe-navigation receivers).
  GeneratedTemplate = Struct.new(:seed, :source, :base_ivars, :states, :aux_files,
    :unmodeled_keys, :helpers, :uses_it_alias, keyword_init: true)

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
      @aux_files = {} # views-root-relative path => source (partial fixtures)
      # JSON keys the template renders that the walker (by design, with a
      # warning) does NOT model — merge! payloads, dynamic set! keys, concat
      # extras. The runner excuses :uncovered_key for exactly these keys and
      # nothing else; a warning no longer demotes the whole template.
      @unmodeled_keys = Set.new
      @helpers = {} # helper method name => fixed return value (defined on the view)
      @partials = [] # {ref:, keys:, locals:, strict:} for partials written to @aux_files
      @seq = 0
      @stmts_left = MAX_STMTS
      # `it` (the implicit block parameter) is a Ruby 3.4+ construct: real
      # jbuilder cannot render a template using it on older Rubies. The walker
      # still parses it statically, so it stays in the grammar for coverage;
      # the runner skips only the RENDER pass below 3.4 (see Runner#run_seed).
      @uses_it_alias = false
    end

    def generate
      roll = @rng.rand
      lines =
        if roll < 0.22
          gen_root_array
        elsif roll < 0.30
          gen_root_collection_partial
        else
          gen_top_level
        end
      GeneratedTemplate.new(
        seed: @seed,
        source: lines.join("\n") + "\n",
        base_ivars: @data.dup,
        states: build_states,
        aux_files: @aux_files.dup,
        unmodeled_keys: @unmodeled_keys.dup,
        helpers: @helpers.dup,
        uses_it_alias: @uses_it_alias
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
        [:ternary] * 5 + [:parens_ternary] * 2 + [:helper] * 2
      pool += [:nil_lit] * 2 if allow_nil
      pool += [:element] * 8 if element

      case pool[@rng.rand(pool.size)]
      when :literal then lit(type)
      when :nil_lit then "nil"
      when :ivar then "@#{data_ivar(sample_value(type))}"
      when :helper
        # A bare no-receiver call the renderer defines on the view; the
        # walker types it via the property's name hint, like an ivar.
        @seq += 1
        @helpers["h#{@seq}"] = sample_value(type)
        "h#{@seq}"
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

    # `json.set!` with a LITERAL key is the same walker path and the same
    # render path as `json.<name>` (set! is aliased as method_missing), so
    # the set! spelling threads through every write site instead of being
    # its own unit. `:name` and `"name"` normalize to one JSON key.
    SET_BANG_PROB = 0.2

    def key_literal(name)
      (@rng.rand < 0.5) ? ":#{name}" : name.inspect
    end

    def write_line(builder, name, expr)
      @stmts_left -= 1
      if @rng.rand < SET_BANG_PROB
        (@rng.rand < 0.1) ? "#{builder}.set!(#{key_literal(name)}, #{expr})" :
          "#{builder}.set! #{key_literal(name)}, #{expr}"
      else
        (@rng.rand < 0.1) ? "#{builder}.#{name}(#{expr})" : "#{builder}.#{name} #{expr}"
      end
    end

    # ---- statement units -----------------------------------------------

    UNIT_WEIGHTS = {
      simple: 4, conditional: 5, reset: 5, object_block: 3, array_block: 2, extract: 2,
      local_line: 2, attr_shortcut: 2, literal_hash: 1, set_dynamic: 1,
      merge: 2, child_array: 2, child_concat_merge: 1,
      annotated: 3, annotated_reset: 2, call_extract: 2,
      partial_merge: 2, cache_block: 2
    }.freeze

    MAX_PARTIALS = 3

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
      if depth >= MAX_DEPTH || !allow_blocks
        pool -= [:object_block, :array_block, :child_array, :child_concat_merge, :cache_block]
      end
      pool -= [:extract, :call_extract, :attr_shortcut] if element

      case pool[@rng.rand(pool.size)]
      when :simple then [simple_line(builder, used, element)]
      when :conditional then conditional_unit(depth: depth, builder: builder, used: used, element: element)
      when :reset then reset_cluster(depth: depth, builder: builder, used: used, element: element)
      when :object_block then object_block(depth: depth, builder: builder, used: used, element: element)
      when :array_block then array_block(depth: depth, builder: builder, used: used)
      when :extract then extract_unit(builder, used)
      when :local_line then local_line_unit(builder, used, element)
      when :attr_shortcut then attr_shortcut_unit(builder, used)
      when :literal_hash then literal_hash_unit(builder, used)
      when :set_dynamic then set_dynamic_unit(builder)
      when :merge then merge_unit(builder: builder, used: used)
      when :child_array then child_array_block(depth: depth, builder: builder, used: used)
      when :child_concat_merge then child_concat_merge_unit(builder: builder, used: used)
      when :annotated then annotated_unit(depth: depth, builder: builder, used: used, element: element)
      when :annotated_reset then annotated_reset(builder: builder, used: used, element: element)
      when :call_extract then extract_unit(builder, used, spelling: pick([:call_paren, :call_named]))
      when :partial_merge then partial_merge_unit(builder: builder, used: used, element: element)
      when :cache_block then cache_block_unit(depth: depth, builder: builder, used: used, element: element)
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

      form = pick([:modifier, :modifier_unless, :if, :if_else, :unless_else,
        :if_else_same_key, :if_else_same_key, :elsif, :elsif_else])
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
      when :elsif, :elsif_else
        # collect_branches walks full elsif chains; fully_covered only with a
        # terminal else. A reused flag makes the elsif arm dead at render —
        # its exclusive keys stay optional either way, so both are sound.
        flag2 = acquire_flag || flag
        b1 = gen_body(depth: depth, builder: builder, used: used, element: element)
        b2 = gen_body(depth: depth, builder: builder, used: used, element: element)
        lines = ["if @#{flag}", *indent(b1), "elsif @#{flag2}", *indent(b2)]
        if form == :elsif_else
          lines.concat(["else", *indent(gen_body(depth: depth, builder: builder, used: used, element: element))])
        end
        lines << "end"
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
      # A valueless child!-block merges into the existing value, so it is
      # only safe while NOTHING but arrays ever landed on the key — a
      # scalar/nil/hash occurrence crashes the merge even when it was
      # conditional (the crash fires in the state where it ran). Array-over-
      # array is safe in both orders (concat/replace).
      array_only_so_far = true
      writes = 2 + ((@rng.rand < 0.35) ? 1 : 0)
      writes.times do |i|
        break if @stmts_left <= 0

        kinds = [:scalar] * 5 + [:nil] * 2
        kinds += [:oblock] * 3 if only_oblocks_so_far && depth < MAX_DEPTH
        kinds += [:ablock] * 2 if depth < MAX_DEPTH
        kinds += [:cblock] * 3 if array_only_so_far && depth < MAX_DEPTH
        kind = kinds[@rng.rand(kinds.size)]
        flag = (@rng.rand < 0.6 && (i > 0 || @rng.rand < 0.5)) ? acquire_flag : nil

        case kind
        when :scalar
          only_oblocks_so_far = false
          array_only_so_far = false
          line = write_line(builder, name, value_expr(name, element: element))
          line += " if @#{flag}" if flag
          lines << line
        when :nil
          only_oblocks_so_far = false
          array_only_so_far = false
          line = write_line(builder, name, "nil")
          line += " if @#{flag}" if flag
          lines << line
        when :oblock
          array_only_so_far = false
          block = object_block(depth: depth, builder: builder, used: Set.new, element: element,
            name: name, allow_alias: false)
          lines.concat(flag ? wrap_if(block, flag) : block)
        when :ablock
          only_oblocks_so_far = false
          block = array_block(depth: depth, builder: builder, used: Set.new, name: name)
          lines.concat(flag ? wrap_if(block, flag) : block)
        when :cblock
          only_oblocks_so_far = false # an oblock after a cblock is a MergeError
          if flag && @rng.rand < 0.4
            # Branch-merged child arrays on the SAME key — the marker-survival
            # regression shape: Property#merge_block_array must ride the copy
            # through merge_branches or a later concat degrades to replace.
            b1 = child_array_block(depth: depth, builder: builder, used: Set.new, name: name)
            b2 = child_array_block(depth: depth, builder: builder, used: Set.new, name: name)
            lines.concat(["if @#{flag}", *indent(b1), "else", *indent(b2), "end"])
          else
            block = child_array_block(depth: depth, builder: builder, used: Set.new, name: name)
            lines.concat(flag ? wrap_if(block, flag) : block)
          end
        end
      end
      lines
    end

    def object_block(depth:, builder:, used:, element:, name: nil, allow_alias: true)
      name ||= fresh_name(used, hint_prob: 0.15)
      @stmts_left -= 1
      style = allow_alias ? pick_weighted(plain: 6, param: 2, it: 1, numbered: 1) : :plain
      inner_used = Set.new

      head = (@rng.rand < SET_BANG_PROB) ? "#{builder}.set! #{key_literal(name)} do" : "#{builder}.#{name} do"
      case style
      when :plain
        # Composed-partial hook: leading positional partial! calls make the
        # block a named-Interface intersection; marking the merged keys in
        # inner_used FIRST keeps the rest of the body disjoint from them (an
        # own-key re-set inside a composed block degrades the intersection).
        lead = []
        if allow_alias && depth < MAX_DEPTH && @rng.rand < 0.2 && @stmts_left > 2
          partial = (@partials.size < MAX_PARTIALS && @rng.rand < 0.5) ? make_partial : @partials.sample(random: @rng)
          lead << partial_call_line(partial, inner_used) if partial
        end
        body = lead + gen_body(depth: depth + 1, builder: "json", used: inner_used, element: element)
        [head, *indent(body), "end"]
      when :param
        @seq += 1
        param = "b#{@seq}"
        body = gen_body(depth: depth + 1, builder: param, used: inner_used, element: element)
        ["#{head} |#{param}|", *indent(body), "end"]
      else
        # `it`/`_1` rebinds per-block, so keep these bodies free of nested
        # blocks (a nested paramless block would silently rebind them).
        inner_builder = (style == :it) ? "it" : "_1"
        @uses_it_alias = true if style == :it
        body = (1 + @rng.rand(2)).times.map { simple_line(inner_builder, inner_used, element) }
        [head, *indent(body), "end"]
      end
    end

    def array_block(depth:, builder:, used:, name: nil)
      name ||= fresh_name(used, hint_prob: 0.1)
      @stmts_left -= 1
      @seq += 1
      param = "e#{@seq}"
      element = {var: param, fields: {}}
      body =
        if depth < MAX_DEPTH && @rng.rand < 0.2
          # child! inside a collection block: jbuilder runs the block once
          # per element and child! turns EACH per-element scope into an array
          # (Array<Array<...>> — the walker's ArrayOf wrapper, REPLACE
          # semantics, no concat marker). The |param| stays unused.
          (1 + @rng.rand(2)).times.flat_map { child_bang(depth: depth + 1) }
        else
          gen_body(depth: depth + 1, builder: "json", used: Set.new, element: element)
        end
      elements = Array.new(1 + @rng.rand(2)) do
        element[:fields].transform_values { |type| sample_value(type) }
      end
      collection = collection_ivar(elements)
      head = (@rng.rand < SET_BANG_PROB) ? "#{builder}.set! #{key_literal(name)}, @#{collection}" :
        "#{builder}.#{name} @#{collection}"
      if @rng.rand < 0.15
        # Annotated collection-value spelling: `[]` is sound ONLY here (the
        # value is genuinely an array); the shape content is checker-opaque.
        shape_key = element[:fields].keys.first || :id
        head += ", typelize: #{"{ #{shape_key}: unknown }[]".inspect}"
      end
      ["#{head} do |#{param}|", *indent(body), "end"]
    end

    # Blockless `json.call`/`json.(...)` is extract! spelled differently —
    # one unit, three spellings.
    def extract_unit(builder, used, spelling: :extract!)
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
      # Same walker path either way; jbuilder extracts Hashes via fetch
      # (_extract_hash_values) and everything else via public_send.
      @data[struct_ivar] = if @rng.rand < 0.4
        attrs.map(&:to_sym).zip(values).to_h
      else
        Struct.new(*attrs.map(&:to_sym)).new(*values)
      end
      @stmts_left -= 1
      # Inert sprinkle: typelize: on extract!/call is walker-inert but
      # exercises SetExt's strip paths on the non-set! emitters at render.
      inert = (@rng.rand < 0.15) ? ", typelize: \"unknown\"" : ""
      syms = attrs.map { |a| ":#{a}" }.join(", ")
      lines = [
        case spelling
        when :call_named then "#{builder}.call @#{struct_ivar}, #{syms}#{inert}"
        when :call_paren then "#{builder}.(@#{struct_ivar}, #{syms}#{inert})"
        else "#{builder}.extract! @#{struct_ivar}, #{syms}#{inert}"
        end
      ]

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

    # A local assignment then a read in value position: the assignment is a
    # silent non-json statement to the walker; the read types via the
    # property's name hint exactly like an ivar (values always match hints).
    def local_line_unit(builder, used, element)
      name = fresh_name(used)
      type = HINT_NAMES[name] || TYPES[@rng.rand(TYPES.size)]
      @seq += 1
      local = "v#{@seq}"
      ["#{local} = #{lit(type)}", write_line(builder, name, local)]
    end

    # `json.author @obj, :a, :b` (and its set! spelling): the walker picks
    # array-vs-object from NAME plurality (looks_like_collection?) while
    # jbuilder decides at runtime via _is_collection? — the grammar keeps the
    # two aligned (singular name + Struct, plural name + array of Structs).
    # Names come from fixed singularize-stable vocabularies: digit-suffixed
    # names would confuse the inflector.
    SINGULAR_ATTR_NAMES = %w[author owner profile badge avatar].freeze
    PLURAL_ATTR_NAMES = %w[entries labels rows cards posts].freeze

    def attr_shortcut_unit(builder, used)
      attrs = []
      (1 + @rng.rand(2)).times do
        if @rng.rand < 0.5
          candidates = HINT_NAMES.keys - attrs
          attrs << candidates[@rng.rand(candidates.size)] unless candidates.empty?
        else
          @seq += 1
          attrs << "zz#{@seq}"
        end
      end
      attrs.uniq!
      collection = @rng.rand < 0.5
      name = ((collection ? PLURAL_ATTR_NAMES : SINGULAR_ATTR_NAMES) - used.to_a).first
      return [simple_line(builder, used, nil)] if attrs.empty? || name.nil?

      used << name
      attrs.each { |a| used << a }
      types = attrs.map { |a| HINT_NAMES[a] || TYPES[@rng.rand(TYPES.size)] }
      build = -> { Struct.new(*attrs.map(&:to_sym)).new(*types.map { |t| sample_value(t) }) }
      ivar = data_ivar(collection ? Array.new(1 + @rng.rand(2)) { build.call } : build.call)
      @stmts_left -= 1
      attr_list = attrs.map { |a| ":#{a}" }.join(", ")
      if @rng.rand < SET_BANG_PROB
        ["#{builder}.set! #{key_literal(name)}, @#{ivar}, #{attr_list}"]
      else
        ["#{builder}.#{name} @#{ivar}, #{attr_list}"]
      end
    end

    # Literal Hash values — brace form (positional HashNode) and the
    # braceless sole-hash form that exercises SetExt's re-pack rule. Both
    # walk to `unknown` (a checker wildcard), so the name must never be
    # hint-typed (a hint type would falsely reject the rendered object).
    def literal_hash_unit(builder, used)
      name = fresh_name(used, hint_prob: 0.0)
      pairs = (1 + @rng.rand(2)).times.map {
        @seq += 1
        "hk#{@seq}: #{lit(TYPES[@rng.rand(TYPES.size)])}"
      }.join(", ")
      @stmts_left -= 1
      if @rng.rand < 0.5
        ["#{builder}.#{name}({#{pairs}})"]
      else
        ["#{builder}.#{name} #{pairs}"]
      end
    end

    # Dynamic-key set! — the walker warns and models nothing, so the key
    # namespace ("dynN") stays disjoint from every literal-keyed property and
    # the write stays a leaf scalar: the only possible violation is
    # :uncovered_key, which the runner excuses on warned templates.
    def set_dynamic_unit(builder)
      @seq += 1
      dyn = "dyn#{@seq}"
      var = "dk#{@seq}"
      @unmodeled_keys << dyn
      key_expr = (@rng.rand < 0.5) ? ":#{dyn}" : dyn.inspect
      @stmts_left -= 1
      ["#{var} = #{key_expr}", "#{builder}.set! #{var}, #{lit(TYPES[@rng.rand(TYPES.size)])}"]
    end

    # ---- partials ---------------------------------------------------------
    #
    # Partial fixtures live beside the seed template ("t42/_p1.json.jbuilder")
    # and are ALWAYS referenced slash-qualified — slash-less refs resolve via
    # controller prefixes the fuzz renderer doesn't have. References form a
    # DAG (a partial may only call an EARLIER partial), locals are non-nil and
    # hint-matching (partial bodies type bare local reads via name hints with
    # nullable:false), and strict-locals signatures always declare `json:`.

    def make_partial
      return nil if @stmts_left <= 1
      idx = @partials.size + 1
      used = Set.new
      local_names = HINT_NAMES.keys.sample(1 + @rng.rand(2), random: @rng)
      locals = local_names.each_with_object({}) { |n, h|
        used << n
        h[n] = HINT_NAMES[n]
      }
      lines = []
      strict = @rng.rand < 0.35
      if strict
        sig = locals.map { |n, t| (@rng.rand < 0.3) ? "#{n}: #{lit(t)}" : "#{n}:" }
        lines << "# locals: (json:, #{sig.join(", ")})" # json: is MANDATORY
      end
      locals.each_key { |n| lines << write_line("json", n, n) }
      lines << simple_line("json", used, nil) if @rng.rand < 0.5
      if @partials.any? && @rng.rand < 0.3
        lines << partial_call_line(@partials[@rng.rand(@partials.size)], used)
      end
      partial = {ref: "t#{@seed}/p#{idx}", keys: used.to_a, locals: locals, strict: strict}
      @aux_files["t#{@seed}/_p#{idx}.json.jbuilder"] = lines.join("\n") + "\n"
      @partials << partial
      partial
    end

    def partial_call_line(partial, used)
      @stmts_left -= 1
      partial[:keys].each { |k| used << k } # merged keys claim the level
      args = partial[:locals].map { |n, t|
        "#{n}: #{(@rng.rand < 0.6) ? lit(t) : "@#{data_ivar(sample_value(t))}"}"
      }.join(", ")
      case pick_weighted(positional: 5, kwargs: 2, kwargs_locals: 2)
      when :positional then "json.partial! \"#{partial[:ref]}\"#{", #{args}" unless args.empty?}"
      when :kwargs then "json.partial!(partial: \"#{partial[:ref]}\"#{", #{args}" unless args.empty?})"
      when :kwargs_locals then "json.partial!(partial: \"#{partial[:ref]}\", locals: {#{args}})"
      end
    end

    # partial! merged into the current scope (root, object block, or array
    # element body), optionally followed by a re-set of one merged key — the
    # locked-union / last-wins hot zone.
    def partial_merge_unit(builder:, used:, element:)
      partial = (@partials.size < MAX_PARTIALS && @rng.rand < 0.5) ? make_partial : @partials.sample(random: @rng)
      return [simple_line(builder, used, element)] unless partial

      lines = [partial_call_line(partial, used)]
      if @rng.rand < 0.3 && @stmts_left > 0
        key = partial[:keys][@rng.rand(partial[:keys].size)]
        line = write_line(builder, key, lit(TYPES[@rng.rand(TYPES.size)]))
        flag = (@rng.rand < 0.5) ? acquire_flag : nil
        lines << (flag ? "#{line} if @#{flag}" : line)
      end
      lines
    end

    # Root collection partial: the template IS the array; the partial reads
    # the `as:` local's hint-named fields.
    def gen_root_collection_partial
      idx = @partials.size + 1
      fields = HINT_NAMES.keys.sample(1 + @rng.rand(2), random: @rng)
      lines = fields.map { |f| write_line("json", f, "row[:#{f}]") }
      @aux_files["t#{@seed}/_p#{idx}.json.jbuilder"] = lines.join("\n") + "\n"
      @partials << {ref: "t#{@seed}/p#{idx}", keys: fields, locals: {}, strict: false}
      elements = Array.new(1 + @rng.rand(2)) do
        fields.to_h { |f| [f.to_sym, sample_value(HINT_NAMES[f])] }
      end
      ["json.partial! partial: \"t#{@seed}/p#{idx}\", collection: @#{collection_ivar(elements)}, as: :row"]
    end

    # cache!/cache_if! yield transparently when the controller reports
    # perform_caching=false (the renderer's stub does); the walker treats
    # them as passthroughs. Writes land in the CURRENT scope, so the block
    # shares the enclosing `used` set.
    def cache_block_unit(depth:, builder:, used:, element:)
      @stmts_left -= 1
      @seq += 1
      body = gen_body(depth: depth + 1, builder: builder, used: used, element: element)
      head =
        if @rng.rand < 0.3 && (flag = acquire_flag)
          "#{builder}.cache_if!(@#{flag}, \"c#{@seq}\") do"
        else
          "#{builder}.cache!(\"c#{@seq}\") do"
        end
      [head, *indent(body), "end"]
    end

    # ---- typelize: annotations ------------------------------------------
    #
    # Core soundness principle: a NARROWING annotation must be exact-or-
    # superset of the value's runtime type set across ALL render states;
    # presence-widening (`?`) and null-widening (`| null`) are always sound;
    # `{...}` shape strings are checker-opaque wildcards.

    ANNOTATION_WILDCARDS = %w[unknown any].freeze

    # Like value_expr, but surfaces what the generator already knows about
    # the expression: [expr, runtime_type, nilable-in-some-state]. Excludes
    # the bare-nil arm (an annotation on a constant nil is degenerate).
    def typed_value_expr(name, element: nil)
      type = HINT_NAMES[name] || TYPES[@rng.rand(TYPES.size)]
      pool = [:literal] * 6 + [:ivar] * 3 + [:safe_nav] * 3 + [:try] * 2 + [:ternary] * 5
      pool += [:element] * 6 if element

      case pool[@rng.rand(pool.size)]
      when :literal then [lit(type), type, false]
      when :ivar then ["@#{data_ivar(sample_value(type))}", type, false]
      when :element then [element_read(name, type, element), type, false]
      when :safe_nav
        maybe = acquire_maybe(name, type)
        maybe ? ["@#{maybe[:ivar]}&.#{maybe[:field]}", type, true] : [lit(type), type, false]
      when :try
        maybe = acquire_maybe(name, type)
        maybe ? ["@#{maybe[:ivar]}.try(:#{maybe[:field]})", type, true] : [lit(type), type, false]
      when :ternary
        flag = acquire_flag
        return [lit(type), type, false] unless flag
        arm1 = (@rng.rand < 0.30) ? "nil" : lit(type)
        arm2 = (arm1 != "nil" && @rng.rand < 0.45) ? "nil" : lit(type)
        ["@#{flag} ? #{arm1} : #{arm2}", type, arm1 == "nil" || arm2 == "nil"]
      end
    end

    # A SOUND annotation string for a value of `type` (+ null when nilable).
    # `?` only ever marks a sole base type — "a | b?" would symbolize a bogus
    # :"b?" member.
    def annotation_for(type, nilable)
      case pick_weighted(exact: 5, extra_member: 3, add_null: 2, optional_mark: 2, wildcard: 1)
      when :exact then nilable ? "#{type} | null" : type
      when :extra_member
        other = (TYPES - [type])[@rng.rand(TYPES.size - 1)]
        [type, other, ("null" if nilable)].compact.join(" | ")
      when :add_null then "#{type} | null"
      when :optional_mark then nilable ? "#{type} | null" : "#{type}?"
      when :wildcard then ANNOTATION_WILDCARDS[@rng.rand(2)]
      end
    end

    def annotated_unit(depth:, builder:, used:, element:)
      name = fresh_name(used)
      if depth < MAX_DEPTH && @rng.rand < 0.25
        annotated_block(depth: depth, builder: builder, used: used, element: element, name: name)
      else
        expr, type, nilable = typed_value_expr(name, element: element)
        line = write_line(builder, name, "#{expr}, typelize: #{annotation_for(type, nilable).inspect}")
        flag = (@rng.rand < 0.3) ? acquire_flag : nil
        flag ? [line + " if @#{flag}"] : [line]
      end
    end

    # Block form: shape content is checker-opaque, so the only soundness
    # obligation is presence — the body's first statement is a guaranteed
    # unconditional write, making both the plain and `?`-suffixed shape sound.
    def annotated_block(depth:, builder:, used:, element:, name:)
      @stmts_left -= 1
      inner = Set.new
      body = [simple_line("json", inner, element)]
      body.concat(gen_body(depth: depth + 1, builder: "json", used: inner, element: element)) if @rng.rand < 0.5
      ann = "{ #{inner.first}: unknown }"
      ann += "?" if @rng.rand < 0.5
      ["#{builder}.#{name}(typelize: #{ann.inspect}) do", *indent(body), "end"]
    end

    # Only the three verified-sound annotated re-set patterns: a dead
    # assertion before an unconditional re-set, a conditional asserted
    # re-set (union keeps both sides), and a branch-covering assertion (an
    # asserted occurrence wins OUTRIGHT across branches, so it must cover
    # BOTH branch types).
    def annotated_reset(builder:, used:, element:)
      name = fresh_name(used, hint_prob: 0)
      t1 = TYPES[@rng.rand(TYPES.size)]
      t2 = TYPES[@rng.rand(TYPES.size)]
      case pick([:dead, :cond_reset, :branch_covering])
      when :dead
        [write_line(builder, name, "#{lit(t1)}, typelize: #{t1.inspect}"),
          write_line(builder, name, lit(t2))]
      when :cond_reset
        flag = acquire_flag
        return [simple_line(builder, used, element)] unless flag
        [write_line(builder, name, lit(t1)),
          write_line(builder, name, "#{lit(t2)}, typelize: #{t2.inspect}") + " if @#{flag}"]
      when :branch_covering
        flag = acquire_flag
        return [simple_line(builder, used, element)] unless flag
        ["if @#{flag}", *indent([write_line(builder, name, lit(t1))]), "else",
          *indent([write_line(builder, name, "#{lit(t2)}, typelize: #{[t1, t2].uniq.join(" | ").inspect}")]), "end"]
      end
    end

    # json.merge! with a LITERAL hash payload. The walker always warns and
    # models nothing, so payload keys surface only as :uncovered_key (excused
    # on warned templates) — but they MUST be reserved through the scope's
    # `used` set: a collision with a typed key would let jbuilder's
    # replace/deep_merge change that key's rendered type (non-excused).
    # Hash payloads only: a bare array/scalar payload replaces or repaints
    # the enclosing scope. Dispatched only from gen_unit (never inside
    # reset_cluster, whose fresh inner `used` sets would allow collisions).
    def merge_unit(builder:, used:)
      @stmts_left -= 1
      pairs = Array.new(1 + @rng.rand(2)) {
        @seq += 1
        key = "mk#{@seq}"
        used << key # reserve: a collision with a typed key would change its rendered type
        @unmodeled_keys << key
        [key, merge_payload]
      }
      line =
        case pick_weighted(braced_string: 3, braced_symbol: 3, braceless: 2, typelize_kwarg: 1)
        when :braced_string
          "#{builder}.merge!({#{pairs.map { |k, v| "\"#{k}\" => #{v}" }.join(", ")}})"
        when :braced_symbol
          "#{builder}.merge!({#{pairs.map { |k, v| "#{k}: #{v}" }.join(", ")}})"
        when :braceless # SetExt's sole-hash repack path
          "#{builder}.merge! #{pairs.map { |k, v| "#{k}: #{v}" }.join(", ")}"
        when :typelize_kwarg # stripped by SetExt before jbuilder's arity-1 merge!
          "#{builder}.merge!({#{pairs.map { |k, v| "#{k}: #{v}" }.join(", ")}}, typelize: \"string\")"
        end
      flag = (@rng.rand < 0.3) ? acquire_flag : nil
      [flag ? "#{line} if @#{flag}" : line]
    end

    # Literal scalars plus one level of nested hash/array — invisible to the
    # walker, so any JSON-valid literal shape works.
    def merge_payload(depth = 0)
      kinds = [:s, :s, :n, :n, :b, :nil]
      kinds += [:hash, :arr] if depth == 0
      case kinds[@rng.rand(kinds.size)]
      when :s then lit("string")
      when :n then lit("number")
      when :b then lit("boolean")
      when :nil then "nil"
      when :hash then "{n#{@seq += 1}: #{merge_payload(1)}}"
      when :arr then "[#{merge_payload(1)}, #{merge_payload(1)}]"
      end
    end

    # `json.<name> do json.child! ... end` — jbuilder's literal-array form.
    # Render-crash invariants: child! calls are the ONLY top-level statements
    # of the wrapper (a named prop AFTER child! raises Jbuilder::ArrayError),
    # every child! is unconditional, block-bearing and argument-free, and
    # every child body has >= 1 unconditional write (a blank child scope
    # appends the BLANK sentinel — garbage JSON, SEVERITY-A).
    def child_array_block(depth:, builder:, used:, name: nil)
      name ||= fresh_name(used, hint_prob: 0.1)
      @stmts_left -= 1
      body = (1 + @rng.rand(2)).times.flat_map { child_bang(depth: depth + 1) }
      head = (@rng.rand < SET_BANG_PROB) ? "#{builder}.set! #{key_literal(name)} do" : "#{builder}.#{name} do"
      [head, *indent(body), "end"]
    end

    # One `json.child!` element. child! yields SELF, so |b|/it/_1 alias the
    # builder exactly like an object block (it/_1 bodies stay block-free).
    def child_bang(depth:)
      @stmts_left -= 1
      inner_used = Set.new
      style = pick_weighted(plain: 6, param: 2, it: 1, numbered: 1)
      case style
      when :param
        @seq += 1
        param = "b#{@seq}"
        body = child_body(depth: depth, builder: param, used: inner_used)
        ["json.child! do |#{param}|", *indent(body), "end"]
      when :it, :numbered
        b = (style == :it) ? "it" : "_1"
        @uses_it_alias = true if style == :it
        body = (1 + @rng.rand(2)).times.map { simple_line(b, inner_used, nil) }
        ["json.child! do", *indent(body), "end"]
      else
        body = child_body(depth: depth, builder: "json", used: inner_used)
        ["json.child! do", *indent(body), "end"]
      end
    end

    # Nested units are fine (NAMED child arrays recurse through gen_unit);
    # raw child! never nests here — child!-in-child! turns the element itself
    # into an array the walker warns on and drops.
    def child_body(depth:, builder:, used:)
      body = (@rng.rand < 0.6 && @stmts_left > 1) ? gen_body(depth: depth, builder: builder, used: used, element: nil) : []
      body + [simple_line(builder, used, nil)] # the guaranteed unconditional write
    end

    # Composite: a child!-built array then a literal-array merge! — jbuilder's
    # Array+Array CONCAT. The walker types elements from the child! branches
    # only (warning about the merge!), so every merged element must cover
    # every child field with a matching-type value (missing_required_key is
    # NOT excused); extra keys are fine (excused :uncovered_key).
    def child_concat_merge_unit(builder:, used:)
      name = fresh_name(used, hint_prob: 0)
      @stmts_left -= 2
      fields = Array.new(1 + @rng.rand(2)) {
        @seq += 1
        ["x#{@seq}", TYPES[@rng.rand(TYPES.size)]]
      }.to_h
      child_lines = fields.map { |f, t| write_line("json", f, lit(t)) }
      elems = Array.new(1 + @rng.rand(2)) do
        entries = fields.map { |f, t| "\"#{f}\" => #{lit(t)}" }
        if @rng.rand < 0.5
          @seq += 1
          @unmodeled_keys << "extra#{@seq}"
          entries << "\"extra#{@seq}\" => #{lit("string")}"
        end
        "{#{entries.join(", ")}}"
      end
      ["#{builder}.#{name} do",
        "  json.child! do", *indent(indent(child_lines)), "  end",
        "  json.merge!([#{elems.join(", ")}])",
        "end"]
    end

    # Root arrays: one to four forms in sequence (consecutive root forms
    # CONCAT; the walker widens every element prop to optional). The FIRST
    # form stays top-level unconditional — a conditional first form would
    # make detect_root_array type the root as an object. `used` is shared
    # across ALL forms: same-name keys across concatenated forms are
    # last-wins in the walker but both render.
    def gen_root_array
      used = Set.new
      forms = [root_array_form(used)]
      @rng.rand(3).times do
        break if @stmts_left <= 0
        form = root_array_form(used)
        if @rng.rand < 0.3 && (flag = acquire_flag)
          form = wrap_if(form, flag)
        end
        forms << form
      end
      forms.flatten(1)
    end

    def root_array_form(used)
      case pick_weighted(block: 6, attrs: 4, range_block: 2, empty: 1, nil_coll: 1)
      when :block then root_array_block(used)
      when :attrs then root_array_attrs(used)
      when :range_block then root_array_range(used)
      when :empty then root_array_block(used, elements: []) # renders []
      when :nil_coll then root_array_block(used, collection_nil: true) # _array nil-guard → []
      end
    end

    def root_array_block(used, elements: nil, collection_nil: false)
      @seq += 1
      param = "e#{@seq}"
      element = {var: param, fields: {}}
      body = []
      (1 + @rng.rand(3)).times do
        body.concat(gen_unit(depth: 1, builder: "json", used: used, element: element))
      end
      body << simple_line("json", used, element) if body.empty?
      collection =
        if collection_nil
          data_ivar(nil)
        else
          elems = elements || Array.new(1 + @rng.rand(2)) do
            element[:fields].transform_values { |type| sample_value(type) }
          end
          collection_ivar(elems)
        end
      @stmts_left -= 1
      header =
        case pick_weighted(array_bang: 5, call_paren: 2, call_named: 1, call_kwarg_only: 1)
        when :array_bang then "json.array! @#{collection} do |#{param}|"
        when :call_paren then "json.(@#{collection}) do |#{param}|"
        when :call_named then "json.call @#{collection} do |#{param}|"
        when :call_kwarg_only
          # SetExt regression probe: annotation-only kwargs + block renders []
          # (the walker still types the element shape; [] conforms vacuously).
          "json.(typelize: #{TYPES[@rng.rand(TYPES.size)].inspect}) do |#{param}|"
        end
      [header, *indent(body), "end"]
    end

    # `json.array! @coll, :attr1, :attr2` — attribute extraction per element.
    def root_array_attrs(used)
      attrs = []
      (1 + @rng.rand(3)).times do
        if @rng.rand < 0.5
          candidates = HINT_NAMES.keys - used.to_a - attrs
          attrs << candidates[@rng.rand(candidates.size)] unless candidates.empty?
        else
          @seq += 1
          attrs << "zz#{@seq}"
        end
      end
      attrs.uniq!
      return root_array_block(used) if attrs.empty?

      attrs.each { |a| used << a }
      elements = Array.new(1 + @rng.rand(2)) do
        # Hint attrs always non-nil, hint-matching; every element answers
        # every attr (public_send on a missing member would raise).
        values = attrs.map { |a| sample_value(HINT_NAMES[a] || TYPES[@rng.rand(TYPES.size)]) }
        Struct.new(*attrs.map(&:to_sym)).new(*values)
      end
      @stmts_left -= 1
      ["json.array! @#{collection_ivar(elements)}, #{attrs.map { |a| ":#{a}" }.join(", ")}"]
    end

    # array! over a Range: the element is a SCALAR Integer, so only
    # number-hint or non-hint (unknown-wildcard) names may read the param.
    def root_array_range(used)
      @seq += 1
      param = "n#{@seq}"
      lo = @rng.rand(3)
      ivar = data_ivar(lo..(lo + @rng.rand(3)))
      names = (1 + @rng.rand(2)).times.map do
        candidates = %w[total page user_id item_id] - used.to_a
        pick_hint = @rng.rand < 0.5 && !candidates.empty?
        pick_hint ? candidates[@rng.rand(candidates.size)] : fresh_name(used, hint_prob: 0.0)
      end
      names.each { |n| used << n }
      body = names.uniq.map { |n| write_line("json", n, param) }
      @stmts_left -= 1
      ["json.array! @#{ivar} do |#{param}|", *indent(body), "end"]
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
