# frozen_string_literal: true

ENV["TYPELIZER"] = "true"
ENV["RAILS_ENV"] = "test"
require File.expand_path("app/config/environment", __dir__)

# Snapshot/restore for the full mutable state of Typelizer.configuration.
#
# Specs that mutate flat (global) settings or writers must restore the exact
# previous state: flat setters write into `@global_settings`, and later specs
# that (re-)register writers rebuild their configs from those globals, so any
# leaked setting shifts output fingerprints and breaks snapshot specs in an
# order-dependent way. Restoring the whole state avoids whack-a-mole per-key
# restoration.
module TypelizerConfigurationState
  STATE_IVARS = %i[
    @dirs
    @listen
    @writers
    @global_settings
    @writer_output_dirs
    @used_output_dirs
  ].freeze

  module_function

  def snapshot(configuration = Typelizer.configuration)
    STATE_IVARS.to_h { |ivar| [ivar, configuration.instance_variable_get(ivar).dup] }
  end

  def restore(snapshot, configuration = Typelizer.configuration)
    snapshot.each { |ivar, value| configuration.instance_variable_set(ivar, value.dup) }
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:suite) do
    # Generated output of the dummy app. Stale files from a previous run
    # interact with Writer#write_file's digest short-circuit, so start clean.
    FileUtils.rm_rf(Rails.root.join("app/javascript/types"))

    # Serializer registration is a load-time side effect: Typelizer::DSL's
    # included/extended hooks push the class name into Typelizer.base_classes
    # when a serializer file is FIRST required, and Typelizer.interfaces
    # requires files lazily (first-time-only per process). Preload them all
    # so the registry is fully populated before any example runs — otherwise
    # the process's first generation cycle can happen inside an example that
    # swapped base_classes (openapi_spec's "no serializers" premise), which
    # both breaks that example's assertion and permanently discards the
    # in-flight registrations for the rest of the process.
    Typelizer.dirs.flat_map { |dir| Dir["#{dir}/**/*.rb"] }.sort.each { |file| require file }
  end
end
