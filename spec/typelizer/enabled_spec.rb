# frozen_string_literal: true

require "spec_helper"

RSpec.describe Typelizer, ".enabled?" do
  around do |example|
    saved_typelizer = ENV.delete("TYPELIZER")
    saved_rails_env = ENV.delete("RAILS_ENV")
    example.run
  ensure
    ENV["TYPELIZER"] = saved_typelizer if saved_typelizer
    ENV["RAILS_ENV"] = saved_rails_env if saved_rails_env
  end

  # Regression: #114 — under rake, ENV["RAILS_ENV"] is nil while Rails.env is set.
  it "returns true when Rails.env is development, even without ENV[RAILS_ENV]" do
    allow(Rails).to receive(:env).and_return(double("Rails.env", development?: true))

    expect(Typelizer.enabled?).to be true
  end

  it "returns false when Rails.env is not development" do
    allow(Rails).to receive(:env).and_return(double("Rails.env", development?: false))

    expect(Typelizer.enabled?).to be false
  end

  it "honors TYPELIZER=true over Rails.env" do
    ENV["TYPELIZER"] = "true"
    allow(Rails).to receive(:env).and_return(double("Rails.env", development?: false))

    expect(Typelizer.enabled?).to be true
  end

  it "honors TYPELIZER=false over Rails.env" do
    ENV["TYPELIZER"] = "false"
    allow(Rails).to receive(:env).and_return(double("Rails.env", development?: true))

    expect(Typelizer.enabled?).to be false
  end
end
