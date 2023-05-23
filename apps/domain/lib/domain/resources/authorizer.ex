defmodule Domain.Resources.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Resources.Resource

  def manage_resources_permission, do: build(Resource, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_resources_permission()
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
    end
  end
end
