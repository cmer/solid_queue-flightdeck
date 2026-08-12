# frozen_string_literal: true

Flightdeck::Engine.routes.draw do
  root to: "overview#index"

  resources :jobs, only: %i[index show] do
    member do
      post :retry, to: "jobs/retries#create"
      post :discard, to: "jobs/discards#create"
    end

    collection do
      post :retry, to: "jobs/retries#create", as: :bulk_retry
      post :discard, to: "jobs/discards#create", as: :bulk_discard
    end
  end

  # Queue names are arbitrary strings (dots, slashes, colons all legal), so the
  # name travels as a parameter rather than as a path segment.
  resources :queues, only: :index do
    collection do
      post :pause
      post :resume
    end
  end

  resources :processes, only: :index do
    member { post :prune }
  end

  resources :recurring_tasks, only: :index do
    member { post :run }
  end

  get "assets/:name",
      to: "assets#show",
      as: :asset_file,
      format: false,
      constraints: { name: /flightdeck-(?:[a-z0-9-]+-)?[0-9a-f]{12}\.(?:css|js|woff2)/ }
end
