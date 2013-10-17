class User
  extend ActiveModel::Naming
  attr_accessor :alchemy_roles, :roles, :email, :password

  def self.logged_in
    []
  end
end
