defmodule Domain.Rules.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Rules.Rule

  def manage_rules_permission, do: build(Rule, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_rules_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_rules_permission()) ->
        queryable
    end
  end
end
