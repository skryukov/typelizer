# frozen_string_literal: true

module Typelizer
  class TypeGenerationError < StandardError; end

  class Middleware
    class << self
      attr_accessor :instance
    end

    def initialize(app)
      @app = app
      @mutex = Mutex.new
      @pending = true
      self.class.instance = self
    end

    def call(env)
      if @pending
        @mutex.synchronize do
          generate! if @pending
        end
      end
      @app.call(env)
    end

    def mark_pending!
      @pending = true
    end

    private

    def generate!
      Generator.new.call
      RouteGenerator.call
      @pending = false
    rescue ActiveRecord::NoDatabaseError,
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::StatementInvalid => e
      raise TypeGenerationError, "Typelizer could not generate types: #{e.message}\n" \
        "Fix the database issue, then reload the page."
    end
  end
end
