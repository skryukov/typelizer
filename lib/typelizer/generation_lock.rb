# frozen_string_literal: true

require "monitor"

module Typelizer
  # Process-wide reentrant lock serializing every generation cycle.
  #
  # Middleware-triggered generation, rake-task generation, and the jbuilder
  # plugin's destructive `reset!`/`discover` re-discovery all synchronize
  # here, so a listen-triggered cycle can never yank `Templates::` constants
  # out from under an in-flight walk. A Monitor (not a Mutex) because cycles
  # nest: `Generator#call` holds the lock across all writers while
  # `Typelizer.interfaces` re-acquires it per writer.
  module GenerationLock
    LOCK = Monitor.new
    private_constant :LOCK

    def self.synchronize(&block)
      LOCK.synchronize(&block)
    end
  end
end
