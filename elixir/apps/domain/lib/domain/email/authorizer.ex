defmodule Domain.Email.Authorizer do
  use Domain.Auth.Authorizer

  alias Domain.Email.{
    AuthProvider
  }

  def manage_auth_providers_permission, do: build(AuthProvider, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_auth_providers_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_auth_providers_permission()
    ]
  end

  def list_permissions_for_role(_), do: []
end
