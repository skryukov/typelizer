# frozen_string_literal: true

module Typelizer
  module DelegateTracker
    @registry = {} # { Class => { method_name => { to:, allow_nil:, original: } } }

    class << self
      attr_reader :registry

      def [](klass, method)
        registry.dig(klass, method)
      end
    end

    module Hook
      def delegate(*methods, to:, allow_nil: nil, prefix: nil, **)
        super.tap do
          next unless is_a?(Class) && defined?(ActiveRecord::Base) && !ActiveRecord.autoload?(:Base) && self < ActiveRecord::Base

          method_prefix = if prefix == true
            "#{to}_"
          else
            prefix ? "#{prefix}_" : ""
          end
          methods.each do |m|
            (DelegateTracker.registry[self] ||= {})[:"#{method_prefix}#{m}"] = {to: to, allow_nil: !!allow_nil, original: m.to_sym}
          end
        end
      end
    end
  end
end

Module.prepend(Typelizer::DelegateTracker::Hook) if Typelizer.enabled?
