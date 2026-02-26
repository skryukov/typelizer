module Alba
  class AbstractBaseSerializer < BaseSerializer
    typelize_from ::AbstractBase

    attributes :custom_attr

    typelize :string
    attribute :label do |object|
      "abstract"
    end
  end
end
