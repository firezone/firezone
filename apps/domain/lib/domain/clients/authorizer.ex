defmodule Domain.Clients.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Clients.Client

  def manage_own_clients_permission, do: build(Client, :manage_own)
  def manage_clients_permission, do: build(Client, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:admin) do
    [
      manage_own_clients_permission(),
      manage_clients_permission()
    ]
  end

  def list_permissions_for_role(:unprivileged) do
    [
      manage_own_clients_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_clients_permission()) ->
        queryable

      has_permission?(subject, manage_own_clients_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        Client.Query.by_user_id(queryable, user_id)
    end
  end
end
