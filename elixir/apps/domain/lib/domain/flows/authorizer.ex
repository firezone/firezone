defmodule Domain.Flows.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Flows.Flow

  def view_flows_permission, do: build(Flow, :view)
  def create_flows_permission, do: build(Flow, :create)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      view_flows_permission(),
      create_flows_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      create_flows_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, view_flows_permission()) ->
        Flow.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
