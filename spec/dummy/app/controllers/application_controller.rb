class ApplicationController < ActionController::Base
  protect_from_forgery

  private

  def current_user
    nil
  end
end
