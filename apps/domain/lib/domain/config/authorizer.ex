defmodule Domain.Config.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Config.Configuration

  def configure_permission, do: build(Configuration, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      configure_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end
end
