defmodule Domain.Entra.Authorizer do
  use Domain.Auth.Authorizer

  alias Domain.Entra.{
    AuthProvider,
    Directory
  }

  def manage_auth_providers_permission, do: build(AuthProvider, :manage)
  def manage_directories_permission, do: build(Directory, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_auth_providers_permission(),
      manage_directories_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_auth_providers_permission(),
      manage_directories_permission()
    ]
  end

  def list_permissions_for_role(_), do: []
end
