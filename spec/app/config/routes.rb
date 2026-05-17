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

  mount BlogEngine::Engine, at: "/blog"
end
