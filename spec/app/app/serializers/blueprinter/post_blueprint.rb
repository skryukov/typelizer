module Blueprinter
  class PostBlueprint < Base
    include Typelizer::DSL

    typelize_from ::Post

    identifier :id
    fields :title, :category, :published_at

    view :summary do
      exclude :published_at
    end
  end
end
