defmodule Domain.Clients.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Clients.Client

  def manage_own_clients_permission, do: build(Client, :manage_own)
  def manage_clients_permission, do: build(Client, :manage)
  def verify_clients_permission, do: build(Client, :verify)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:account_admin_user) do
    [
      manage_own_clients_permission(),
      manage_clients_permission(),
      verify_clients_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_own_clients_permission(),
      manage_clients_permission(),
      verify_clients_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      manage_own_clients_permission()
    ]
  end

  def list_permissions_for_role(:service_account) do
    [
      manage_own_clients_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_clients_permission()) ->
        Client.Query.by_account_id(queryable, subject.account.id)

      has_permission?(subject, manage_own_clients_permission()) ->
        queryable
        |> Client.Query.by_account_id(subject.account.id)
        |> Client.Query.by_actor_id(subject.actor.id)
    end
  end
end
