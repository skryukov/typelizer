# frozen_string_literal: true

# Load-safety check against a bundle with NO prism gem — run it as
#
#   BUNDLE_GEMFILE=gemfiles/no_prism.gemfile bundle exec ruby spec/support/no_prism_check.rb
#
# Unlike jbuilder_loading_spec's $LOADED_FEATURES simulation, this exercises
# real absence: the only prism reachable is Ruby's bundled default gem (none
# before 3.3, 0.19 on 3.3, >= 1.0 on 3.4+), so the expected outcome is
# version-dependent — either the actionable activation error, or activation
# through a genuinely usable bundled prism. Not part of the rspec suite.

def check(condition, message)
  abort("FAIL: #{message}") unless condition
end

check !defined?(Prism), "Prism constant defined before require"
check $LOADED_FEATURES.grep(/prism/).empty?, "prism loaded before require"

require "typelizer"

check !defined?(Prism), "requiring typelizer defined Prism"
check $LOADED_FEATURES.grep(/prism/).empty?, "requiring typelizer loaded prism"
check !defined?(::Jbuilder), "requiring typelizer defined Jbuilder"

# The user scenario: a jbuilder app enables the plugin but forgot the gem.
require "jbuilder"

begin
  walker = Typelizer::SerializerPlugins::Jbuilder.activate_walker!
  # Success is legitimate only via a bundled prism the walker can use.
  check defined?(Prism::VERSION) && Gem::Version.new(Prism::VERSION) >= Gem::Version.new("1.0"),
    "activation succeeded without a usable prism (#{defined?(Prism::VERSION) ? Prism::VERSION : "none"})"
  puts "OK: activated via bundled prism #{Prism::VERSION} (#{walker})"
rescue Typelizer::Error => e
  check e.message.include?("prism"), "activation error lacks prism remediation: #{e.message}"
  puts "OK: actionable activation error (#{e.message.lines.first.strip})"
end
