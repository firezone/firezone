defmodule Domain.Config.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Config.Configuration

  def manage_permission, do: build(Configuration, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end
end
