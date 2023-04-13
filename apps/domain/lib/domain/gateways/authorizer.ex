defmodule Domain.Gateways.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Gateways.Gateway

  def manage_gateways_permission, do: build(Gateway, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:admin) do
    [
      manage_gateways_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_gateways_permission()) ->
        Gateway.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
