defmodule FzHttp.Config.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Config.Configuration

  def configure_permission, do: build(Configuration, :manage)

  @impl FzHttp.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      configure_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end
end
