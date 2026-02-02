# frozen_string_literal: true

module UserDelegatable
  extend ActiveSupport::Concern

  included do
    delegate :role, to: :user, prefix: :user, allow_nil: true
  end
end
