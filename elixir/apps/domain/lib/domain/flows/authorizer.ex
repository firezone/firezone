defmodule Domain.Flows.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Flows.{Flow, Activity}

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

  def list_permissions_for_role(:service_account) do
    [
      create_flows_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  def for_subject(queryable, Flow, %Subject{} = subject) do
    cond do
      has_permission?(subject, view_flows_permission()) ->
        Flow.Query.by_account_id(queryable, subject.account.id)
    end
  end

  def for_subject(queryable, Activity, %Subject{} = subject) do
    cond do
      has_permission?(subject, view_flows_permission()) ->
        Activity.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
