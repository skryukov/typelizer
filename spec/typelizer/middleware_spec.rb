# frozen_string_literal: true

require "typelizer/middleware"

RSpec.describe Typelizer::Middleware do
  let(:inner_app) { ->(env) { [200, {}, ["OK"]] } }
  let(:middleware) { described_class.new(inner_app) }
  let(:env) { {} }

  after do
    described_class.instance = nil
  end

  describe "#initialize" do
    it "sets the class-level instance" do
      expect(middleware).to eq(described_class.instance)
    end
  end

  describe "#call" do
    it "generates types on first request" do
      generator = instance_double(Typelizer::Generator)
      expect(Typelizer::Generator).to receive(:new).and_return(generator)
      expect(generator).to receive(:call)
      expect(Typelizer::RouteGenerator).to receive(:call)

      middleware.call(env)
    end

    it "does not regenerate on subsequent requests" do
      generator = instance_double(Typelizer::Generator)
      expect(Typelizer::Generator).to receive(:new).once.and_return(generator)
      expect(generator).to receive(:call).once
      expect(Typelizer::RouteGenerator).to receive(:call).once

      middleware.call(env)
      middleware.call(env)
    end

    it "raises TypeGenerationError on DB error" do
      expect(Typelizer::Generator).to receive(:new).and_raise(
        ActiveRecord::NoDatabaseError.new("no db")
      )

      expect { middleware.call(env) }.to raise_error(Typelizer::TypeGenerationError, /no db/)
    end

    it "retries generation on the next request after a DB error" do
      call_count = 0
      generator = instance_double(Typelizer::Generator)

      allow(Typelizer::Generator).to receive(:new) do
        call_count += 1
        if call_count == 1
          raise ActiveRecord::NoDatabaseError, "no db"
        end
        generator
      end
      allow(generator).to receive(:call)
      allow(Typelizer::RouteGenerator).to receive(:call)

      expect { middleware.call(env) }.to raise_error(Typelizer::TypeGenerationError)

      # Second call retries and succeeds
      result = middleware.call(env)
      expect(result).to eq([200, {}, ["OK"]])
    end

    it "re-raises non-database errors directly" do
      expect(Typelizer::Generator).to receive(:new).and_raise(
        RuntimeError.new("bug in serializer")
      )

      expect { middleware.call(env) }.to raise_error(RuntimeError, "bug in serializer")
    end
  end

  describe "#mark_pending!" do
    it "causes regeneration on the next request" do
      generator = instance_double(Typelizer::Generator)
      expect(Typelizer::Generator).to receive(:new).twice.and_return(generator)
      expect(generator).to receive(:call).twice
      expect(Typelizer::RouteGenerator).to receive(:call).twice

      middleware.call(env)
      middleware.mark_pending!
      middleware.call(env)
    end
  end
end
