# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rspec-snapshot", "~> 2.0"

gem "standard", "~> 1.3"

gem "oj_serializers"

gem "active_model_serializers"

gem "alba"

gem "panko_serializer"

gem "jbuilder"

# The jbuilder plugin activates prism lazily at runtime (with an actionable
# error when it's missing), so prism is deliberately NOT a gemspec
# dependency. The suite's jbuilder specs DO need it — declare it here so
# every CI Ruby (3.0+) resolves it deterministically instead of relying on
# a transitive pick (all prism 1.x support Ruby >= 2.7).
gem "prism", ">= 1.0"

# Rails app
gem "rails", "~> 7.1.3"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "tzinfo-data", platforms: %i[windows jruby]
gem "rspec-rails"

gem "json_schemer"
