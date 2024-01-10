defmodule Domain.Resources.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Resources.Resource

  def manage_resources_permission, do: build(Resource, :manage)
  def view_available_resources_permission, do: build(Resource, :view_available_resources)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_resources_permission(),
      view_available_resources_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      view_available_resources_permission()
    ]
  end

  def list_permissions_for_role(:service_account) do
    [
      view_available_resources_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_resources_permission()) ->
        Resource.Query.by_account_id(queryable, subject.account.id)

      has_permission?(subject, view_available_resources_permission()) ->
        Resource.Query.by_account_id(queryable, subject.account.id)
        |> Resource.Query.by_authorized_actor_id(subject.actor.id)
    end
  end
end
