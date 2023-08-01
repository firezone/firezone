defmodule Domain.Policies.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Policies.Policy

  def manage_policies_permission, do: build(Policy, :manage)
  def view_available_policies_permission, do: build(Policy, :view_available_policies)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_policies_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      view_available_policies_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_policies_permission()) ->
        Policy.Query.by_account_id(queryable, subject.account.id)

      # TODO: for end users we must return only policies that user has access to
      has_permission?(subject, view_available_policies_permission()) ->
        Policy.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
