# frozen_string_literal: true

module Alba
  class CustomOutputDirSerializer < BaseSerializer
    typelizer_config do |c|
      c.output_dir = Rails.root.join("app/javascript/types/custom_output")
    end

    typelize_from ::User
    attributes :id, :username

    has_many :posts, resource: PostSerializer
  end
end
