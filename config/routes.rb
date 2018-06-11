Rails.application.routes.draw do
  
  mount Riiif::Engine => 'images', as: :riiif if Hyrax.config.iiif_image_server?
    concern :searchable, Blacklight::Routes::Searchable.new

  resource :catalog, only: [:index], as: 'catalog', path: '/catalog', controller: 'catalog' do
    concerns :searchable
  end

  devise_for :users
  mount Qa::Engine => '/authorities'
  mount Hyrax::Engine, at: '/'
  resources :welcome, only: 'index'
  root 'hyrax/homepage#index'
  curation_concerns_basic_routes
  concern :exportable, Blacklight::Routes::Exportable.new

  resources :solr_documents, only: [:show], path: '/catalog', controller: 'catalog' do
    concerns :exportable
  end

  resources :bookmarks do
    concerns :exportable

    collection do
      delete 'clear'
    end
  end

  namespace :hyrax,  path: :concern do
    resources :data_sets do
      member do
        post 'tombstone'
        get  'doi'
      end
    end
  end

  mount Blacklight::Engine => '/'
  
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
end
