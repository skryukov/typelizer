module Blueprinter
  module Inherited
    class ExtendedUserBlueprint < UserBlueprint
      typelizer_config.inheritance_strategy = :inheritance

      field :updated_at
    end
  end
end
