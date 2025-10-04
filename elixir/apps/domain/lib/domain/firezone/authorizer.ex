defmodule Domain.Firezone.Authorizer do
  use Domain.Auth.Authorizer

  alias Domain.Firezone.Directory

  def manage_directories_permission, do: build(Directory, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_directories_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_directories_permission()
    ]
  end

  def list_permissions_for_role(_), do: []
end
