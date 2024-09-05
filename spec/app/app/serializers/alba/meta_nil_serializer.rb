module Alba
  class MetaNilSerializer < BaseSerializer
    typelize_from ::User
    attributes :id

    meta nil
  end
end
