require_relative "../lib/blog_engine"

Rails.application.routes.draw do
  root "pages#index"

  resources :users do
    resources :posts, only: [:index, :show]
  end

  resources :posts

  namespace :admin do
    resources :users, only: [:index, :show, :destroy]
  end

  get "pages/*path", to: "pages#show", as: :page
  get "archive(/:year)(/:month)", to: "posts#archive", as: :archive

  # Named + unnamed alias to same action (mirrors ActiveStorage representations)
  get "/aliased/main/:id", to: "aliased_things#show", as: :aliased
  get "/aliased/:id", to: "aliased_things#show"

  # Shallow nesting under two parents defines the same member routes twice
  resources :teams, only: [] do
    resources :comments, shallow: true
  end
  resources :groups, only: [] do
    resources :comments, shallow: true
  end

  # Same resource routed top-level and nested
  resources :replies, only: [:show, :update, :destroy]
  resources :teams, only: [] do
    resources :replies, only: [:show, :update, :destroy]
  end

  mount BlogEngine::Engine, at: "/blog"
end
