defmodule Domain.ConnectivityChecks.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.ConnectivityChecks.ConnectivityCheck

  def view_connectivity_checks_permission, do: build(ConnectivityCheck, :view)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      view_connectivity_checks_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    queryable
  end
end
