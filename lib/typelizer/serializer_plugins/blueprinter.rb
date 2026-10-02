require_relative "base"
require_relative "trait_interface"

module Typelizer
  module SerializerPlugins
    class Blueprinter < Base
      CONDITIONAL_OPTIONS = %i[if unless exclude_if_nil].freeze

      def properties
        view_properties(:default)
      end

      # Each extra view becomes its own full type, since views can also exclude fields
      def trait_interfaces
        @trait_interfaces ||= (serializer.reflections.keys - %i[default identifier]).map do |view|
          TraitInterface.new(serializer: serializer, trait_name: view, context: context, plugin: self, suffix: "View")
        end
      end

      def trait_properties(view)
        typelizes = serializer.respond_to?(:_typelizer_attributes) ? serializer._typelizer_attributes : {}
        [view_properties(view), typelizes]
      end

      private

      def view_properties(view)
        reflection = serializer.reflections.fetch(view)
        reflection.fields.values.map { |field| field_property(field) } +
          reflection.associations.values.map { |association| association_property(association) }
      end

      def field_property(field)
        Property.new(
          name: field.display_name,
          optional: optional?(field.options),
          nullable: false,
          multi: false,
          column_name: field.name
        )
      end

      # `multi` stays nil: Blueprinter renders a list or a single object depending
      # on the value, so the model's association decides
      def association_property(association)
        Property.new(
          name: association.display_name,
          type: association_type(association),
          optional: optional?(association.options),
          nullable: false,
          multi: nil,
          column_name: association.name
        )
      end

      def association_type(association)
        blueprint = association.blueprint
        return unless blueprint.is_a?(Class)

        interface = context.interface_for(blueprint)
        return interface if association.view == :default

        interface.trait_interfaces.find { |view| view.trait_name == association.view }&.name
      end

      def optional?(options)
        CONDITIONAL_OPTIONS.any? { |key| options.key?(key) }
      end
    end
  end
end
