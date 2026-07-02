# frozen_string_literal: true

# Differential fuzzer for the jbuilder plugin: generates deterministic
# templates (grammar v1 — statically supported constructs only), runs the
# walker side (Typelizer::Jbuilder.template + WriterContext#interface_for)
# and the render side (real jbuilder outside Rails) for every conditional
# state, and validates each rendered document against the emitted typed
# model.
#
# NOT auto-loaded by spec_helper — require it explicitly:
#
#   require_relative "../support/jbuilder_fuzz/harness"
#
# For a large local campaign, see big_run.rb in this directory.
require "json"
require "set"
require "stringio"
require "tmpdir"
require "fileutils"
require "jbuilder"

require_relative "generator"
require_relative "checker"
require_relative "renderer"
require_relative "runner"
