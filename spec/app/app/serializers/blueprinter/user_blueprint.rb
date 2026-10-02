module Blueprinter
  class UserBlueprint < Base
    include Typelizer::DSL

    typelize_from ::User

    identifier :id
    fields :username, :active, :role
    field :name, name: :display_name
    field :created_at, if: ->(_field, _user, options) { options[:admin] }

    typelize :string
    field :first_name do |user, _options|
      user.username.split(" ").first
    end

    association :invitor, blueprint: UserBlueprint
    association :posts, blueprint: PostBlueprint, view: :summary

    view :extended do
      field :invitor_id
      association :friends, blueprint: UserBlueprint, view: :extended
      association :latest_post, blueprint: PostBlueprint, view: :identifier
    end
  end
end
