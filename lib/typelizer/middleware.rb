# frozen_string_literal: true

require_relative "error"
require_relative "generation_lock"

module Typelizer
  class TypeGenerationError < Error; end

  class Middleware
    class << self
      attr_accessor :instance
    end

    def initialize(app)
      @app = app
      @pending = true
      self.class.instance = self
    end

    def call(env)
      if @pending
        # Shared (reentrant) lock instead of a per-instance mutex: jbuilder
        # re-discovery and listen-triggered cycles synchronize on the same
        # lock, so generation never interleaves with a destructive `reset!`.
        GenerationLock.synchronize do
          generate! if @pending
        end
      end
      @app.call(env)
    end

    def mark_pending!
      @pending = true
    end

    private

    # Recoverable generation failures (database not ready, template-level
    # errors like a jbuilder NameCollision) re-raise as TypeGenerationError —
    # a readable dev-mode error page instead of a raw 500 — and leave
    # @pending set so the next request retries after the user fixes the
    # issue. Anything else (genuine bugs) propagates untouched.
    def generate!
      Generator.new.call
      RouteGenerator.call
      @pending = false
    rescue *db_error_classes, Typelizer::Error => e
      raise TypeGenerationError, "Typelizer could not generate types: #{e.message}\n" \
        "Fix the error, then reload the page."
    end

    def db_error_classes
      return [] unless defined?(ActiveRecord)

      [
        ActiveRecord::NoDatabaseError,
        ActiveRecord::ConnectionNotEstablished,
        ActiveRecord::StatementInvalid
      ]
    end
  end
end
