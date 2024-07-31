module Alba
  class MetaSerializer < BaseSerializer
    root_key!

    attributes username: [String, true], full_name: String

    typelize address: "{city: string, zipcode: string}"
    nested_attribute :address do
      attributes :city, :zipcode
    end

    typelize_meta metadata: "{foo: 'bar'}"
    meta :metadata do
      {foo: :bar}
    end
  end
end
