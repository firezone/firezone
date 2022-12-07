defmodule FzHttp.ApiTokens do
  @moduledoc """
  The ApiTokens context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.ApiTokens.ApiToken

  def list_api_tokens do
    Repo.all(ApiToken)
  end

  def list_api_tokens(user_id) do
    Repo.all(from a in ApiToken, where: a.user_id == ^user_id)
  end

  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  def create_api_token(attrs \\ %{}) do
    %ApiToken{}
    |> ApiToken.changeset(attrs)
    |> Repo.insert()
  end

  def revoke!(%ApiToken{} = api_token) do
    api_token
    |> ApiToken.changeset(%{revoked_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  def revoked?(%ApiToken{} = api_token) do
    revoked?(api_token.id)
  end

  def revoked?(id) do
    Repo.exists?(
      from a in ApiToken,
        where: not is_nil(a.revoked_at),
        where: a.id == ^id
    )
  end
end
