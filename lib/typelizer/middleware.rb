# frozen_string_literal: true

module Typelizer
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
    rescue => e
      @pending = false # don't retry every request
      if database_error?(e)
        Typelizer.logger.warn(
          "[Typelizer] Skipping type generation: #{e.message}\n" \
          "Run pending migrations, then: bin/rails typelizer:generate"
        )
      else
        raise
      end
    end

    def database_error?(error)
      case error
      when ActiveRecord::NoDatabaseError,
           ActiveRecord::ConnectionNotEstablished
        true
      when ActiveRecord::StatementInvalid
        true
      else
        error.class.name.start_with?("PG::")
      end
    end
  end
end
