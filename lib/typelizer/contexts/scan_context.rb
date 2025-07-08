# frozen_string_literal: true

module Typelizer
  # Builds a minimal plugin used during scan time
  class ScanContext
    class InvalidOperationError < StandardError; end

    # Interface creation is not available during DSL scanning phase (TracePoint)
    def self.interface_for(serializer_class)
      class_name = serializer_class&.name || "unknown class"
      raise InvalidOperationError,
        "Interface creation is not allowed during DSL scan (#{class_name})"
    end

    # just in case, if we call ScanContext like an object
    def interface_for(serializer_class)
      self.class.interface_for(serializer_class)
    end
  end
end
