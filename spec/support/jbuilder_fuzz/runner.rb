# frozen_string_literal: true

module JbuilderFuzz
  # Drives one seed end-to-end: generate a template, register it with the
  # walker, capture the emitted typed model + warnings, render every state
  # with real jbuilder, and validate each render against the model.
  #
  # Severity (generator-scoped contracts, not template-wide warned status):
  #   - the generator DECLARES which rendered keys the walker will not model
  #     (GeneratedTemplate#unmodeled_keys — merge! payloads, dynamic set!
  #     keys, concat extras); an :uncovered_key on exactly those keys is
  #     excused, and nothing else is
  #   - every other violation is SEVERITY-A: the grammar only generates
  #     constructs whose typed behavior the dossiers pin down, so a surviving
  #     divergence is a walker/checker/grammar bug, never expected noise.
  #     (A template-wide "warned" excusal would let one merge! statement
  #     mask violations from every other statement in the seed.)
  #   - warnings alone never fail; the warned count is reported as a stat
  #   - a render crash is a generator/grammar defect, recorded separately
  module Runner
    Divergence = Struct.new(:seed, :severity, :kind, :path, :detail, :state_desc, :rendered, keyword_init: true)
    SeedResult = Struct.new(:seed, :template, :warnings, :ts_output, :divergences, :render_crashes, :walker_crash, keyword_init: true)

    module_function

    def run_seed(seed, views_root:)
      template = Generator.new(seed).generate
      rel = "t#{seed}/show.json.jbuilder"
      full = File.join(views_root, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, template.source)
      # Partial fixtures referenced by the seed (walk side auto-registers
      # "_"-prefixed files; render side resolves them through ActionView).
      (template.aux_files || {}).each do |aux_rel, aux_source|
        aux_full = File.join(views_root, aux_rel)
        FileUtils.mkdir_p(File.dirname(aux_full))
        File.write(aux_full, aux_source)
      end

      Typelizer::Jbuilder.reset!
      klass = Typelizer::Jbuilder.template(rel, views_root: views_root)

      model = nil
      ts_output = nil
      walker_error = nil
      warnings = capture_warnings do
        ctx = Typelizer::WriterContext.new(writer_name: nil)
        iface = ctx.interface_for(klass)
        model = {
          properties: iface.properties,
          root_is_array: iface.root_is_array,
          root_array_element: iface.root_array_element
        }
        ts_output = Typelizer::Renderer.call("interface.ts.erb", interface: iface)
      rescue => e
        walker_error = e
      end

      result = SeedResult.new(seed: seed, template: template, warnings: warnings,
        ts_output: ts_output, divergences: [], render_crashes: [])

      if walker_error
        result.walker_crash = "#{walker_error.class}: #{walker_error.message}\n  " +
          Array(walker_error.backtrace).first(5).join("\n  ")
        result.divergences << Divergence.new(seed: seed, severity: :A, kind: :walker_crash,
          path: "$", detail: result.walker_crash)
        return result
      end

      unmodeled = template.unmodeled_keys || Set.new
      template.states.each do |state|
        ivars = template.base_ivars.merge(state[:ivars])
        rendered =
          begin
            Renderer.render(views_root: views_root, template: "t#{seed}/show",
              ivars: ivars, helpers: template.helpers || {})
          rescue => e
            result.render_crashes << {state: state[:desc], error: "#{e.class}: #{e.message}"}
            next
          end

        Checker.check(model, rendered, unmodeled: unmodeled).each do |violation|
          result.divergences << Divergence.new(
            seed: seed,
            severity: :A,
            kind: violation.kind,
            path: violation.path,
            detail: violation.detail,
            state_desc: state[:desc],
            rendered: rendered
          )
        end
      end
      result
    ensure
      Typelizer::Jbuilder.reset!
    end

    def capture_warnings
      io = StringIO.new
      original = Typelizer.logger
      Typelizer.logger = Logger.new(io)
      begin
        yield
      ensure
        Typelizer.logger = original
      end
      io.string.lines.select { |line| line.match?(/WARN|ERROR/) }.map(&:strip)
    end

    # A self-contained reproduction report for one seed's divergences.
    def format_result(result)
      out = +"seed=#{result.seed}\n"
      out << "--- template (#{result.template.states.size} render state(s)) ---\n"
      out << result.template.source
      out << "--- base ivars ---\n"
      result.template.base_ivars.each { |name, value| out << "  @#{name} = #{value.inspect}\n" }
      out << "--- warnings ---\n"
      out << (result.warnings.any? ? result.warnings.map { |w| "  #{w}\n" }.join : "  (none)\n")
      out << "--- emitted type ---\n#{result.ts_output}\n" if result.ts_output
      result.render_crashes.each do |crash|
        out << "--- RENDER CRASH [#{crash[:state]}] #{crash[:error]}\n"
      end
      result.divergences.each do |d|
        out << "--- [SEVERITY-#{d.severity}] #{d.kind} at #{d.path}"
        out << " [#{d.state_desc}]" if d.state_desc
        out << "\n    #{d.detail}\n"
        out << "    rendered: #{JSON.generate(d.rendered)}\n" if d.rendered
      end
      out
    end

    def format_failures(results, limit: 8)
      failing = results.select { |r| r.divergences.any? }
      out = +"#{failing.size} seed(s) with divergences " \
        "(#{failing.sum { |r| r.divergences.count { |d| d.severity == :A } }} SEVERITY-A, " \
        "#{failing.sum { |r| r.divergences.count { |d| d.severity == :B } }} SEVERITY-B). " \
        "First #{[limit, failing.size].min} shown:\n\n"
      failing.first(limit).each { |r| out << format_result(r) << "\n" }
      out
    end

    # Deduplication key for a divergence: the violation kind + structural
    # features of the template statements that mention the offending key.
    # Groups thousands of seed-level divergences into a handful of
    # mechanism-level clusters.
    def mechanism_signature(divergence, source)
      return [:walker_crash, :A, []] if divergence.kind == :walker_crash

      leaf = divergence.path.to_s.split(/[.\[\]]/).reject(&:empty?).last
      lines = leaf ? source.lines.select { |l| l.match?(/\b#{Regexp.escape(leaf)}\b/) } : []
      joined = lines.join
      features = []
      features << :safe_nav if joined.include?("&.")
      features << :try if joined.include?(".try(")
      features << :parens_value if joined.match?(/\w \(/)
      features << :ternary if joined.include?("?")
      features << :nil_literal if joined.match?(/\bnil\b/)
      features << :block if joined.match?(/\bdo\b/)
      features << :extract if joined.include?("extract!")
      features << :conditional if joined.match?(/\b(if|unless)\b/) || source.match?(/^\s*(if|unless) @/)
      features << :multi_write if leaf && lines.count { |l| l.match?(/\.#{Regexp.escape(leaf)}[ (]/) } > 1
      features << :branch_reuse if leaf && source.include?("else") && lines.size > 1
      features << :root_array if source.lstrip.start_with?("json.array!")
      [divergence.kind, divergence.severity, features.sort]
    end
  end
end
