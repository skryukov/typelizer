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
# grammar extension legitimately raises coverage).
#
# Ruby's Coverage only instruments files compiled AFTER Coverage.start, so
# the ordering below is load-bearing: boot the dummy app first (walker.rb
# loads lazily via activate_walker!, so it is NOT yet compiled), then start
# Coverage, then let the first seed pull the walker in — instrumented.
ENV["TYPELIZER"] ||= "true"
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../app/config/environment", __dir__)

WALKER_PATH = File.expand_path("../../../lib/typelizer/serializer_plugins/jbuilder/walker.rb", __dir__)
RATCHET_PATH = File.join(__dir__, "coverage_ratchet.json")

if $LOADED_FEATURES.include?(WALKER_PATH)
  abort "walker.rb was compiled before Coverage.start — coverage would be blind. " \
    "Something in the dummy app boot now activates the walker eagerly; fix that first."
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

walker = Coverage.result[WALKER_PATH]
abort "no coverage recorded for walker.rb — was it never loaded?" unless walker

lines = walker[:lines]
executable = lines.count { |hits| !hits.nil? }
covered_lines = lines.count { |hits| hits && hits > 0 }
line_pct = (100.0 * covered_lines / executable).round(2)

branch_total = 0
branch_taken = 0
uncovered = []
walker[:branches].each do |site, branches|
  branches.each do |branch, count|
    branch_total += 1
    if count > 0
      branch_taken += 1
    else
      type, _id, start_line, = branch
      site_type, _sid, site_line, = site
      uncovered << [start_line, "#{type} of #{site_type}@#{site_line}"]
    end
  end
end
branch_pct = (100.0 * branch_taken / branch_total).round(2)

source_lines = File.readlines(WALKER_PATH)
puts "walker coverage — fuzz seeds #{from}..#{to} " \
  "(#{severity_a} SEVERITY-A divergences, #{harness_errors} harness errors)"
puts "  lines:    #{covered_lines}/#{executable} (#{line_pct}%)"
puts "  branches: #{branch_taken}/#{branch_total} (#{branch_pct}%)"
puts
puts "=== #{uncovered.size} uncovered branches (grammar-gap worklist) ==="
uncovered.sort.chunk_while { |a, b| a[0] == b[0] }.each do |group|
  line = group[0][0]
  labels = group.map { |_, label| label }.join(", ")
  puts format("  L%-5d %-28s %s", line, labels, source_lines[line - 1].strip)
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
