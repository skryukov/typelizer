# frozen_string_literal: true

require "spec_helper"

RSpec.describe Typelizer::DSL::Disabled do
  let(:class_methods) do
    Module.new do
      include Typelizer::DSL::ClassMethods
      prepend Typelizer::DSL::Disabled
    end
  end

  let(:klass) do
    mod = class_methods
    Class.new { extend mod }
  end

  describe "#typelize_from" do
    it "does not define _typelizer_model_name" do
      klass.typelize_from(Object)

      expect(klass.respond_to?(:_typelizer_model_name)).to be false
    end
  end

  describe "#typelize" do
    it "does not record attribute metadata" do
      klass.typelize(name: :string)

      expect(klass.instance_variable_get(:@_typelizer_attributes)).to be_nil
    end

    it "does not set keyless_type when called with a positional type" do
      klass.typelize(:string)

      expect(klass.keyless_type).to be_nil
    end

    it "accepts the full signature without raising" do
      expect { klass.typelize(:string, {optional: true}, name: :integer) }.not_to raise_error
    end
  end

  describe "#typelize_meta" do
    it "does not record meta attribute metadata" do
      klass.typelize_meta(foo: :string)

      expect(klass.instance_variable_get(:@_typelizer_meta_attributes)).to be_nil
    end
  end
end
