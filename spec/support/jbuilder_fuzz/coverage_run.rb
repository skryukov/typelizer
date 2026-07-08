# frozen_string_literal: true

# Grammar-coverage ratchet for the differential fuzzer. Measures how much of
# the walker the fuzz corpus actually exercises: an uncovered walker branch
# is a GRAMMAR GAP (a construct the fuzzer never generates), not a
# code-quality stat. This is the instrument that catches "the fuzzer ran
# clean because it never looked there".
#
#   bundle exec ruby spec/support/jbuilder_fuzz/coverage_run.rb [FROM] [TO] [--update]
#
# Defaults to seeds 1..200 (the CI gate corpus). Compares walker line/branch
# coverage against the floor checked into coverage_ratchet.json and exits
# non-zero on regression; prints every uncovered branch as a worklist.
# --update rewrites the floor to the measured values (do this only when a
# grammar extension legitimately raises coverage). Run --update on the LOWEST
# supported Ruby: prism parses `it` per the running Ruby's syntax version, so
# walker coverage is Ruby-dependent and the floor must be the matrix minimum
# (see the note in coverage_ratchet.json).
#
# Ruby's Coverage only instruments files compiled AFTER Coverage.start, so
# the ordering below is load-bearing: boot the dummy app first (walker.rb
# and its walker/ collaborators load lazily via activate_walker!, so they
# are NOT yet compiled), then start Coverage, then let the first seed pull
# the walker in — instrumented.
ENV["TYPELIZER"] ||= "true"
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../app/config/environment", __dir__)

# The walker facade plus every extracted collaborator under walker/ — the
# measured line set is the same code that used to live in walker.rb alone,
# so the ratchet percentages stay comparable across the decomposition.
WALKER_DIR = File.expand_path("../../../lib/typelizer/serializer_plugins/jbuilder", __dir__)
WALKER_PATHS = ([File.join(WALKER_DIR, "walker.rb")] +
  Dir[File.join(WALKER_DIR, "walker", "*.rb")]).sort
RATCHET_PATH = File.join(__dir__, "coverage_ratchet.json")

if (preloaded = WALKER_PATHS.select { |path| $LOADED_FEATURES.include?(path) }).any?
  abort "#{preloaded.map { |p| File.basename(p) }.join(", ")} compiled before Coverage.start — " \
    "coverage would be blind. Something in the dummy app boot now activates the walker " \
    "eagerly; fix that first."
end

require "coverage"
Coverage.start(lines: true, branches: true)

require_relative "harness"

update = ARGV.delete("--update")
from = (ARGV[0] || 1).to_i
to = (ARGV[1] || 200).to_i

views_root = Dir.mktmpdir("typelizer-fuzz-coverage")
severity_a = 0
harness_errors = 0
(from..to).each do |seed|
  result = JbuilderFuzz::Runner.run_seed(seed, views_root: views_root)
  severity_a += result.divergences.count { |d| d.severity == :A }
rescue
  harness_errors += 1
end
FileUtils.rm_rf(views_root)

coverage = Coverage.result
if (unrecorded = WALKER_PATHS.reject { |path| coverage.key?(path) }).any?
  abort "no coverage recorded for #{unrecorded.map { |p| File.basename(p) }.join(", ")} — " \
    "was the walker never loaded?"
end

executable = 0
covered_lines = 0
branch_total = 0
branch_taken = 0
uncovered = []
WALKER_PATHS.each do |path|
  data = coverage.fetch(path)
  lines = data[:lines]
  executable += lines.count { |hits| !hits.nil? }
  covered_lines += lines.count { |hits| hits && hits > 0 }

  file = File.basename(path)
  source_lines = File.readlines(path)
  data[:branches].each do |site, branches|
    branches.each do |branch, count|
      branch_total += 1
      if count > 0
        branch_taken += 1
      else
        type, _id, start_line, = branch
        site_type, _sid, site_line, = site
        uncovered << [file, start_line, "#{type} of #{site_type}@#{site_line}", source_lines[start_line - 1].strip]
      end
    end
  end
end
line_pct = (100.0 * covered_lines / executable).round(2)
branch_pct = (100.0 * branch_taken / branch_total).round(2)

puts "walker coverage — fuzz seeds #{from}..#{to} " \
  "(#{severity_a} SEVERITY-A divergences, #{harness_errors} harness errors)"
puts "  lines:    #{covered_lines}/#{executable} (#{line_pct}%)"
puts "  branches: #{branch_taken}/#{branch_total} (#{branch_pct}%)"
puts
puts "=== #{uncovered.size} uncovered branches (grammar-gap worklist) ==="
uncovered.sort.chunk_while { |a, b| a[0] == b[0] && a[1] == b[1] }.each do |group|
  file, line, _, source = group[0]
  labels = group.map { |entry| entry[2] }.join(", ")
  puts format("  %s:L%-5d %-28s %s", file, line, labels, source)
end

if update
  File.write(RATCHET_PATH, JSON.pretty_generate(
    seeds: "#{from}..#{to}", walker: {line_pct: line_pct, branch_pct: branch_pct}
  ) + "\n")
  puts "\nratchet updated: #{RATCHET_PATH}"
  exit 0
end

unless File.exist?(RATCHET_PATH)
  abort "\nno ratchet file yet — run with --update to pin the current floor."
end

floor = JSON.parse(File.read(RATCHET_PATH))["walker"]
failures = []
failures << "line #{line_pct}% < floor #{floor["line_pct"]}%" if line_pct < floor["line_pct"]
failures << "branch #{branch_pct}% < floor #{floor["branch_pct"]}%" if branch_pct < floor["branch_pct"]

if failures.any?
  puts "\nRATCHET FAILED: #{failures.join("; ")}"
  puts "The grammar (or seed corpus) exercises less of the walker than it used to."
  exit 1
end

headroom = [line_pct - floor["line_pct"], branch_pct - floor["branch_pct"]].min
if headroom > 0.5
  puts "\nratchet passed with #{headroom.round(2)}pt headroom — raise the floor with --update."
else
  puts "\nratchet passed."
end
