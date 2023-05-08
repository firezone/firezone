defmodule Domain.Actors.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Actors.Actor

  def manage_actors_permission, do: build(Actor, :manage)
  def edit_own_profile_permission, do: build(Actor, :edit_own_profile)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_actors_permission(),
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(:unprivileged) do
    [
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_actors_permission()) ->
        Actor.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
