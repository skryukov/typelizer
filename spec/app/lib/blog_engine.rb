# frozen_string_literal: true

module BlogEngine
  class Engine < ::Rails::Engine
    isolate_namespace BlogEngine
  end
end

# Minimal controller for route resolution
module BlogEngine
  class ArticlesController < ActionController::Base
  end
end

BlogEngine::Engine.routes.draw do
  resources :articles, only: [:index, :show]
end
