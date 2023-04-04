defmodule Domain.ApiTokens.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.ApiTokens.ApiToken

  def manage_own_api_tokens_permission, do: build(ApiToken, :manage_own)
  def manage_api_tokens_permission, do: build(ApiToken, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_own_api_tokens_permission(),
      manage_api_tokens_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_api_tokens_permission()) ->
        queryable

      has_permission?(subject, manage_own_api_tokens_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        ApiToken.Query.by_user_id(queryable, user_id)
    end
  end

  def ensure_can_manage(%Subject{} = subject, %ApiToken{} = api_token) do
    cond do
      has_permission?(subject, manage_api_tokens_permission()) ->
        :ok

      has_permission?(subject, manage_own_api_tokens_permission()) ->
        {:user, %{id: user_id}} = subject.actor

        if api_token.user_id == user_id do
          :ok
        else
          {:error, :unauthorized}
        end

      true ->
        {:error, :unauthorized}
    end
  end
end
