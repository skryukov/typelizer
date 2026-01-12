# frozen_string_literal: true

module Typelizer
  module SerializerPlugins
    class Alba::TraitAttributeCollector
      attr_reader :collected_attributes, :collected_typelizes

      def initialize
        @collected_attributes = {}
        @collected_typelizes = {}
        @pending_typelize = nil
      end

      def attributes(*names, **options)
        names.each do |name|
          @collected_attributes[name] = name
        end
      end

      def attribute(name, **options, &block)
        @collected_attributes[name] = block || name
        # Apply pending typelize to this attribute
        if @pending_typelize
          @collected_typelizes[name] = @pending_typelize
          @pending_typelize = nil
        end
      end

      # Capture typelize calls - they apply to the next attribute
      # Handles both:
      #   typelize :string, nullable: true  (type with options, applies to next attribute)
      #   typelize attr_name: [:string, nullable: true]  (hash-style, applies to specific attribute)
      def typelize(type_or_hash = nil, **options)
        if type_or_hash.is_a?(Hash)
          # typelize({name: [:string, nullable: true]}) - explicit hash
          type_or_hash.each do |attr_name, type_def|
            @collected_typelizes[attr_name] = normalize_typelize(type_def)
          end
        elsif type_or_hash.nil? && options.any?
          # typelize name: [:string, nullable: true] - Ruby passes as kwargs
          # Check if this looks like attribute definitions (values are arrays or have type-like keys)
          if options.values.first.is_a?(Array) || options.values.first.is_a?(Symbol) || options.values.first.is_a?(String)
            options.each do |attr_name, type_def|
              @collected_typelizes[attr_name] = normalize_typelize(type_def)
            end
          else
            # typelize :string, nullable: true - type with options
            @pending_typelize = normalize_typelize(nil, **options)
          end
        else
          # typelize :string - applies to the next attribute
          @pending_typelize = normalize_typelize(type_or_hash, **options)
        end
      end

      # Simple struct to hold association info from traits
      TraitAssociation = Struct.new(:name, :resource, :with_traits, :multi, :key, keyword_init: true)

      # Support association methods that might be used in traits
      def one(name, **options, &block)
        resource = options[:resource] || options[:serializer]
        with_traits = options[:with_traits]
        key = options[:key] || name
        @collected_attributes[key] = TraitAssociation.new(
          name: name,
          resource: resource,
          with_traits: with_traits,
          multi: false,
          key: key
        )
      end

      alias_method :has_one, :one
      alias_method :association, :one

      def many(name, **options, &block)
        resource = options[:resource] || options[:serializer]
        with_traits = options[:with_traits]
        key = options[:key] || name
        @collected_attributes[key] = TraitAssociation.new(
          name: name,
          resource: resource,
          with_traits: with_traits,
          multi: true,
          key: key
        )
      end

      alias_method :has_many, :many

      # Ignore other DSL methods that might be called
      def method_missing(method_name, *args, **kwargs, &block)
        # Silently ignore unknown methods
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end

      private

      def normalize_typelize(type_def, **options)
        case type_def
        when Array
          # [:string, nullable: true] or ['string?', nullable: true]
          type, *rest = type_def
          opts = rest.first || {}
          TypeParser.parse(type, **opts)
        when Symbol, String
          TypeParser.parse(type_def, **options)
        else
          options
        end
      end
    end
  end
end
