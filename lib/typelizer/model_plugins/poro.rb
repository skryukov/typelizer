module Typelizer
  module ModelPlugins
    class Poro
      # We don't care about initialization
      def initialize(...)
      end

      def infer_types(prop)
        prop
      end

      def comment_for(prop)
        nil
      end

      def enum_for(prop)
        nil
      end
    end
  end
end
