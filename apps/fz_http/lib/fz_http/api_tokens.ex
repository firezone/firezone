defmodule FzHttp.ApiTokens do
  @moduledoc """
  The ApiTokens context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.ApiTokens.ApiToken

  def count_by_user_id(user_id) do
    Repo.aggregate(from(a in ApiToken, where: a.user_id == ^user_id), :count)
  end

  def list_api_tokens do
    Repo.all(ApiToken)
  end

  def list_api_tokens(user_id) do
    Repo.all(from a in ApiToken, where: a.user_id == ^user_id)
  end

  def get_api_token(id), do: Repo.get(ApiToken, id)

  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  def get_unexpired_api_token(api_token_id) do
    now = DateTime.utc_now()

    Repo.one(
      from a in ApiToken,
        where: a.id == ^api_token_id and a.expires_at >= ^now
    )
  end

  def new_api_token(attrs \\ %{}) do
    ApiToken.create_changeset(attrs)
  end

  def create_user_api_token(%FzHttp.Users.User{} = user, params) do
    changeset =
      params
      |> Enum.into(%{"user_id" => user.id})
      |> ApiToken.create_changeset(count_per_user: count_by_user_id(user.id))

    with {:ok, api_token} <- Repo.insert(changeset) do
      FzHttp.Telemetry.create_api_token()
      {:ok, api_token}
    end
  end

  def api_token_expired?(%ApiToken{} = api_token) do
    DateTime.diff(api_token.expires_at, DateTime.utc_now()) < 0
  end

  def delete_api_token(%ApiToken{} = api_token) do
    with {:ok, api_token} <- Repo.delete(api_token) do
      FzHttp.Telemetry.delete_api_token(api_token)
      {:ok, api_token}
    end
  end
end
