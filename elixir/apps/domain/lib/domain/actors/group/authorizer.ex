defmodule Domain.Actors.Group.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Actors.{Actor, Group}

  def manage_actor_groups_permission, do: build(Group, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_actor_groups_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_actor_groups_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    []
  end

  def list_permissions_for_role(_role) do
    []
  end

  def ensure_has_access_to(%Group{} = group, %Subject{} = subject) do
    if group.account_id == subject.account.id do
      Domain.Auth.ensure_has_permissions(subject, manage_actor_groups_permission())
    else
      {:error, :unauthorized}
    end
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_actor_groups_permission()) ->
        by_account_id(queryable, subject.account.id)
    end
  end

  defp by_account_id(queryable, account_id) do
    cond do
      Ecto.Query.has_named_binding?(queryable, :groups) ->
        Group.Query.by_account_id(queryable, account_id)

      Ecto.Query.has_named_binding?(queryable, :actors) ->
        Actor.Query.by_account_id(queryable, account_id)
    end
  end
end
