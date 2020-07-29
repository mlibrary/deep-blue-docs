# frozen_string_literal: true

# see: https://www.dwightwatson.com/posts/accessing-rails-routes-helpers-from-anywhere-in-your-app/
module Routeable
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end

  def default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

end
