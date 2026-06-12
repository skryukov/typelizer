# frozen_string_literal: true

require "typelizer/middleware"

# Generation-time Typelizer errors (e.g. a jbuilder NameCollision) must
# surface through the middleware as a readable TypeGenerationError instead of
# a raw 500, leave the middleware pending, and recover on the next request
# once the underlying error is fixed.
RSpec.describe Typelizer::Middleware, "Typelizer::Error handling" do
  let(:inner_app) { ->(env) { [200, {}, ["OK"]] } }
  let(:middleware) { described_class.new(inner_app) }
  let(:env) { {} }

  after do
    described_class.instance = nil
  end

  it "re-raises a NameCollision as a readable TypeGenerationError, stays pending, and recovers on the next good cycle" do
    call_count = 0
    generator = instance_double(Typelizer::Generator)

    allow(Typelizer::Generator).to receive(:new) do
      call_count += 1
      if call_count == 1
        raise Typelizer::Jbuilder::NameCollision,
          'type name "Dup" is declared by both a/_dup.json.jbuilder and b/_dup.json.jbuilder'
      end
      generator
    end
    allow(generator).to receive(:call)
    allow(Typelizer::RouteGenerator).to receive(:call)

    expect { middleware.call(env) }.to raise_error(Typelizer::TypeGenerationError) { |error|
      expect(error.message).to include('type name "Dup" is declared by both')
      expect(error.message).to include("Fix the error, then reload the page.")
    }

    # @pending stayed true: the next request retries the generation cycle
    # and, with the collision gone, serves the request normally.
    expect(middleware.call(env)).to eq([200, {}, ["OK"]])
    expect(Typelizer::Generator).to have_received(:new).twice
  end
end
