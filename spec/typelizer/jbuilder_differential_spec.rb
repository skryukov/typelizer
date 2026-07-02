# frozen_string_literal: true

# Differential fuzzing of the jbuilder plugin against real jbuilder renders,
# over a FIXED, fully deterministic seed corpus (no time or global-random
# dependence): each seed expands to a template + ivar environment via
# Random.new(seed), the walker emits its typed model, real jbuilder renders
# every conditional state, and the checker validates each render against the
# emitted type. See spec/support/jbuilder_fuzz/harness.rb for the harness
# and severity rules (SEVERITY-A = unwarned type rejects a real render).
require "jbuilder"
require_relative "../support/jbuilder_fuzz/harness"

module JbuilderFuzzCorpus
  SEEDS = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
    61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
    81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100,
    101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120,
    121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140,
    141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160,
    161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
    181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200
  ].freeze

  # The corpus is deterministic, so run it once and share the results across
  # examples (each seed registers/reset!s its own template registry state).
  def self.results
    @results ||= begin
      views_root = Dir.mktmpdir("typelizer-fuzz-ci")
      begin
        SEEDS.map { |seed| JbuilderFuzz::Runner.run_seed(seed, views_root: views_root) }
      ensure
        FileUtils.rm_rf(views_root)
        Typelizer::Jbuilder.reset!
      end
    end
  end
end

RSpec.describe "Jbuilder differential fuzzing (fixed corpus)" do
  def corpus_results
    JbuilderFuzzCorpus.results
  end

  it "generates the same template for the same seed (deterministic corpus)" do
    [JbuilderFuzzCorpus::SEEDS.first, 42, JbuilderFuzzCorpus::SEEDS.last].each do |seed|
      first = JbuilderFuzz::Generator.new(seed).generate
      second = JbuilderFuzz::Generator.new(seed).generate
      expect(second.source).to eq(first.source)
      expect(second.base_ivars.inspect).to eq(first.base_ivars.inspect)
      expect(second.states).to eq(first.states)
    end
  end

  it "only generates templates real jbuilder can render (grammar contract)" do
    crashes = corpus_results.flat_map { |r|
      r.render_crashes.map { |c| "seed=#{r.seed} [#{c[:state]}] #{c[:error]}\n#{r.template.source}" }
    }
    expect(crashes).to be_empty, "generated templates crashed real jbuilder:\n#{crashes.join("\n")}"
  end

  it "emits types that accept every rendered state (zero SEVERITY-A divergences)" do
    failing = corpus_results.select { |r| r.divergences.any? { |d| d.severity == :A } }
    expect(failing).to be_empty, JbuilderFuzz::Runner.format_failures(failing, limit: 8)
  end
end
