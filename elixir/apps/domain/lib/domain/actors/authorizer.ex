defmodule Domain.Actors.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Actors.{Actor, Group}

  def manage_actors_permission, do: build(Actor, :manage)
  def edit_own_profile_permission, do: build(Actor, :edit_own_profile)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_actors_permission(),
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_actors_permission(),
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  def ensure_has_access_to(%Actor{} = actor, %Subject{} = subject) do
    if actor.account_id == subject.account.id do
      Domain.Auth.ensure_has_permissions(subject, manage_actors_permission())
    else
      {:error, :unauthorized}
    end
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_actors_permission()) ->
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
