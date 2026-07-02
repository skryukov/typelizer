# frozen_string_literal: true

# Large local differential-fuzzing campaign for the jbuilder plugin.
# NOT part of the rspec suite — run it directly:
#
#   bundle exec ruby spec/support/jbuilder_fuzz/big_run.rb [FROM] [TO] [REPORT_PATH]
#
# Runs seeds FROM..TO (default 1..2000), deduplicates the divergences by
# MECHANISM (violation kind + structural features of the offending
# statements, not by seed), and prints a cluster table with one minimal
# exemplar (fewest template lines) per cluster.
ENV["TYPELIZER"] ||= "true"
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../app/config/environment", __dir__)
require_relative "harness"

from = (ARGV[0] || 1).to_i
to = (ARGV[1] || 2000).to_i
out = ARGV[2] ? File.open(ARGV[2], "w") : $stdout

views_root = Dir.mktmpdir("typelizer-fuzz-big")
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
clusters = Hash.new { |h, k| h[k] = [] }
crashes = []
harness_errors = []
stats = Hash.new(0)

(from..to).each do |seed|
  begin
    result = JbuilderFuzz::Runner.run_seed(seed, views_root: views_root)
  rescue => e
    harness_errors << [seed, "#{e.class}: #{e.message}"]
    next
  end
  stats[:seeds] += 1
  stats[:warned] += 1 if result.warnings.any?
  stats[:states] += result.template.states.size
  result.render_crashes.each { |c| crashes << [seed, c] }
  seed_has_a = false
  result.divergences.each do |d|
    stats[:"sev_#{d.severity}"] += 1
    seed_has_a ||= d.severity == :A
    signature = JbuilderFuzz::Runner.mechanism_signature(d, result.template.source)
    clusters[signature] << [d, result]
  end
  stats[:seeds_with_a] += 1 if seed_has_a
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
FileUtils.rm_rf(views_root)

out.puts "jbuilder differential fuzz — seeds #{from}..#{to} in #{elapsed.round(1)}s"
out.puts "seeds: #{stats[:seeds]} | render states: #{stats[:states]} | warned templates: #{stats[:warned]}"
out.puts "divergences: #{stats[:sev_A]} SEVERITY-A / #{stats[:sev_B]} SEVERITY-B | seeds with A: #{stats[:seeds_with_a]}"
out.puts "render crashes: #{crashes.size} | harness errors: #{harness_errors.size}"
harness_errors.first(10).each { |seed, err| out.puts "  HARNESS ERROR seed=#{seed}: #{err}" }
crashes.first(10).each { |seed, c| out.puts "  RENDER CRASH seed=#{seed} [#{c[:state]}] #{c[:error]}" }

out.puts
out.puts "=== #{clusters.size} mechanism clusters (by kind + severity + statement features) ==="
sorted = clusters.sort_by { |sig, hits| [(sig[1] == :A) ? 0 : 1, -hits.size] }
sorted.each_with_index do |(signature, hits), i|
  kind, severity, features = signature
  seeds = hits.map { |_, r| r.seed }.uniq
  out.puts
  out.puts "--- cluster #{i + 1}: #{kind} [SEVERITY-#{severity}] features=#{features.inspect}"
  out.puts "    #{hits.size} divergence(s) across #{seeds.size} seed(s); sample seeds: #{seeds.first(12).inspect}"
end

out.puts
out.puts "=== minimal exemplar per cluster ==="
sorted.each_with_index do |(signature, hits), i|
  divergence, result = hits.min_by { |_, r| r.template.source.lines.size }
  kind, severity, features = signature
  out.puts
  out.puts "#" * 72
  out.puts "# cluster #{i + 1}: #{kind} [SEVERITY-#{severity}] features=#{features.inspect}"
  out.puts "# exemplar divergence: #{divergence.path} [#{divergence.state_desc}]"
  out.puts "#" * 72
  out.puts JbuilderFuzz::Runner.format_result(result)
end
out.close unless out == $stdout
