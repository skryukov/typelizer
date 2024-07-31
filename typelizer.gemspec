# frozen_string_literal: true

require_relative "lib/typelizer/version"

Gem::Specification.new do |spec|
  spec.name = "typelizer"
  spec.version = Typelizer::VERSION
  spec.authors = ["Svyatoslav Kryukov"]
  spec.email = ["me@skryukov.dev"]

  spec.summary = "A TypeScript type generator for Ruby serializers."
  spec.description = "A TypeScript type generator for Ruby serializers."
  spec.homepage = "https://github.com/skryukov/typelizer"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}/blob/main/README.md",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["{app,lib}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 6.0.0"
end
