defmodule FzHttp.Rules.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Rules.Rule

  def manage_rules_permission, do: build(Rule, :manage)

  @impl FzHttp.Auth.Authorizer
  def list_permissions do
    [
      manage_rules_permission()
    ]
  end

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_rules_permission()) ->
        queryable
    end
  end

  # TODO: part of behaviour?
  def ensure_can_manage(%Subject{} = subject, %Rule{} = _rule) do
    cond do
      has_permission?(subject, manage_rules_permission()) ->
        :ok
    end
  end
end
