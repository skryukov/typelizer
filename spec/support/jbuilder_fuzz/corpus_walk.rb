# frozen_string_literal: true

# Real-world corpus walk: run the jbuilder walker over harvested open-source
# app view trees. Static walk only (no rendering — no app data or models),
# so `unknown` rates reflect the walker WITHOUT model inference. NOT part of
# the rspec suite — run it against a local corpus:
#
#   # harvest (blob-filtered sparse clones, .jbuilder files only):
#   git clone --depth 1 --filter=blob:none --no-checkout https://github.com/<repo>.git <dir>
#   (cd <dir> && git sparse-checkout set --no-cone '**/*.jbuilder' && git checkout HEAD)
#
#   bundle exec ruby spec/support/jbuilder_fuzz/corpus_walk.rb <corpus_root> <out_dir>
#
# Reports per repo: templates discovered, interfaces built, crashes,
# warning volume, and the unknown-rate of the emitted TS; snapshots every
# emitted interface under <out_dir> for eyeballing.
ENV["TYPELIZER"] ||= "true"
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../app/config/environment", __dir__)
require "stringio"
require "logger"
require "fileutils"

corpus_root = ARGV.fetch(0)
out_dir = ARGV.fetch(1)
FileUtils.mkdir_p(out_dir)

def capture_warnings
  io = StringIO.new
  original = Typelizer.logger
  Typelizer.logger = Logger.new(io)
  begin
    yield
  ensure
    Typelizer.logger = original
  end
  io.string.lines.select { |l| l.match?(/WARN|ERROR/) }.map(&:strip)
end

grand = Hash.new(0)
crash_samples = Hash.new { |h, k| h[k] = [] }

Dir.children(corpus_root).sort.each do |repo|
  repo_dir = File.join(corpus_root, repo)
  next unless File.directory?(repo_dir)

  # Every `views` directory with jbuilder templates beneath it is a root:
  # partial references resolve relative to it, exactly like in the app.
  views_roots = Dir.glob("**/views", base: repo_dir)
    .map { |rel| File.join(repo_dir, rel) }
    .select { |dir| Dir.glob("**/*.json.jbuilder", base: dir).any? }
  next if views_roots.empty?

  stats = Hash.new(0)
  repo_out = File.join(out_dir, repo)

  views_roots.each do |views_root|
    Typelizer::Jbuilder.reset!
    discover_warnings = capture_warnings do
      Typelizer::Jbuilder.discover(views_root)
    rescue => e
      stats[:discover_crashes] += 1
      crash_samples["DISCOVER #{e.class}: #{e.message.lines.first&.strip}"] << views_root.sub(corpus_root, "")
    end
    stats[:discover_warnings] += discover_warnings.size

    Typelizer::Jbuilder::Templates.constants.sort.each do |const|
      klass = Typelizer::Jbuilder::Templates.const_get(const)
      next unless klass.respond_to?(:_template_path)
      stats[:templates] += 1

      output = nil
      warnings = capture_warnings do
        ctx = Typelizer::WriterContext.new(writer_name: nil)
        iface = ctx.interface_for(klass)
        output = Typelizer::Renderer.call("interface.ts.erb", interface: iface)
      rescue StandardError, SystemStackError => e
        stats[:crashes] += 1
        key = "#{e.class}: #{e.message.lines.first&.strip&.slice(0, 110)}"
        crash_samples[key] << klass._template_path.sub(corpus_root, "")
      end
      next unless output

      stats[:ok] += 1
      stats[:warnings] += warnings.size
      stats[:warned_templates] += 1 if warnings.any?
      props = output.scan(/^ {2,}[\w"'\[\]]+\??: /).size
      unknowns = output.scan(/: unknown[;\[ |]/).size
      stats[:props] += props
      stats[:unknown_props] += unknowns

      rel = klass._template_path.sub(/\A#{Regexp.escape(views_root)}\/?/, "").sub(/\.json\.jbuilder\z/, ".ts")
      snap = File.join(repo_out, rel)
      FileUtils.mkdir_p(File.dirname(snap))
      File.write(snap, output)
    end
  end
  Typelizer::Jbuilder.reset!

  rate = stats[:props].zero? ? 0 : (100.0 * stats[:unknown_props] / stats[:props]).round(1)
  puts format("%-42s templates=%-4d ok=%-4d crashes=%-3d warned=%-4d props=%-5d unknown=%d%%",
    repo, stats[:templates], stats[:ok], stats[:crashes] + stats[:discover_crashes],
    stats[:warned_templates], stats[:props], rate)
  stats.each { |k, v| grand[k] += v }
end

puts
rate = grand[:props].zero? ? 0 : (100.0 * grand[:unknown_props] / grand[:props]).round(1)
puts "TOTAL templates=#{grand[:templates]} ok=#{grand[:ok]} crashes=#{grand[:crashes] + grand[:discover_crashes]} " \
  "warned=#{grand[:warned_templates]} props=#{grand[:props]} unknown-rate=#{rate}%"
puts
puts "=== crash clusters (#{crash_samples.size}) ==="
crash_samples.sort_by { |_, v| -v.size }.each do |msg, paths|
  puts "#{paths.size}x #{msg}"
  paths.first(3).each { |p| puts "    #{p}" }
end
