defmodule Domain.Tokens.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Tokens.Token

  def manage_own_tokens_permission, do: build(Token, :manage_own)
  def manage_tokens_permission, do: build(Token, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_tokens_permission(),
      manage_own_tokens_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      manage_own_tokens_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl true
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_tokens_permission()) ->
        Token.Query.by_account_id(queryable, subject.account.id)

      has_permission?(subject, manage_own_tokens_permission()) ->
        queryable
        |> Token.Query.by_account_id(subject.account.id)
        |> Token.Query.by_actor_id(subject.actor.id)
    end
  end
end
