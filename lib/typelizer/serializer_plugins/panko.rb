require_relative "base"

module Typelizer
  module SerializerPlugins
    class Panko < Base
      def methods_to_typelize
        [:has_many, :has_one, :belongs_to, :attribute]
      end

      def properties
        puts serializer
        attributes = serializer.new.instance_variable_get(:@descriptor).attributes
        associations = serializer.new.instance_variable_get(:@descriptor).has_many_associations

        attributes.map do |att|
          Property.new(
            name: att.name,
            type: infer_type_from_model(att.name), # options[:type] ||
            optional: false, #options.key?(:if) || options.key?(:unless),
            nullable: false, #options[:nullable] || false,
            multi: false,
            column_name: att.name
          )
        end + associations.map do |assoc|
          key = assoc.name_str
          serializer = assoc.descriptor.type
          type = serializer ? Interface.new(serializer: serializer) : infer_type_from_association(key)
          Property.new(
            name: key,
            type: type,
            optional: false, #options.key?(:if) || options.key?(:unless),
            nullable: false, # options[:nullable] || false,
            multi: true, # options[:has_many] || false,
            column_name: key
          )
        end
      end

      private

      def infer_type_from_model(attribute)
        model_class = serializer.instance_variable_get(:@model_class)
        return "unknown" unless model_class

        column = model_class.columns_hash[attribute.to_s]
        column ? column.type : "unknown"
      end

      def infer_type_from_association(attribute)
        assoc = serializer.instance_variable_get(:@model_class).reflect_on_association(attribute)
        assoc ? assoc.klass.name : "unknown"
      end
    end
  end
end
