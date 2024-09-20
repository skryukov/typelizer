module Typelizer
  # InlineType is mainly used with Alba plugin to represent inline associations.
  # `name `method` is the same interface as `Interface` class.
  class InlineType
    TEMPLATE = <<~ERB.strip
      {
        <%- properties.each do |property| %>
          <%= property %>;
        <% end %>
      }
    ERB
    def initialize(serializer:, config:)
      @serializer = serializer
      @config = config
    end

    def name
      properties = SerializerPlugins::Alba.new(serializer: @serializer, config: @config).properties
      ERB.new(TEMPLATE, trim_mode: "-").result_with_hash(properties: properties)
    end
  end
end
