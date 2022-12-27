defmodule FzHttp.ApiTokens do
  @moduledoc """
  The ApiTokens context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.ApiTokens.ApiToken

  def count, do: count(ApiToken)
  def count(nil), do: nil

  def count(queryable) when is_struct(queryable) or is_atom(queryable),
    do: Repo.aggregate(queryable, :count)

  def count(user_id), do: count(from(a in ApiToken, where: a.user_id == ^user_id))

  def list_api_tokens do
    Repo.all(ApiToken)
  end

  def list_api_tokens(user_id) do
    Repo.all(from a in ApiToken, where: a.user_id == ^user_id)
  end

  def get_api_token(id), do: Repo.get(ApiToken, id)

  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  def new_api_token(attrs \\ %{}) do
    ApiToken.changeset(%ApiToken{}, attrs)
  end

  def create_api_token(attrs \\ %{}) do
    FzHttp.Telemetry.create_api_token()
    user_id = attrs[:user_id] || attrs["user_id"]

    %ApiToken{}
    |> ApiToken.changeset(attrs, count_per_user: count(user_id))
    |> Repo.insert()
  end

  def expired?(%ApiToken{} = api_token) do
    DateTime.diff(api_token.expires_at, DateTime.utc_now()) < 0
  end

  def delete_api_token(%ApiToken{} = api_token) do
    with {:ok, api_token} <- Repo.delete(api_token) do
      FzHttp.Telemetry.delete_api_token(api_token)
      {:ok, api_token}
    end
  end
end
