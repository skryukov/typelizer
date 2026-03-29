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

  mount BlogEngine::Engine, at: "/blog"
end
