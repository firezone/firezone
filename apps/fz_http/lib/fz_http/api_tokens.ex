defmodule FzHttp.ApiTokens do
  alias FzHttp.{Repo, Validator}
  alias FzHttp.Users
  alias FzHttp.ApiTokens.ApiToken

  def count_by_user_id(user_id) do
    ApiToken.Query.by_user_id(user_id)
    |> Repo.aggregate(:count)
  end

  def list_api_tokens do
    ApiToken.Query.all()
    |> Repo.list()
  end

  def list_api_tokens_by_user_id(user_id) do
    ApiToken.Query.by_user_id(user_id)
    |> Repo.list()
  end

  def fetch_api_token_by_id(id) do
    if Validator.valid_uuid?(id) do
      ApiToken.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_unexpired_api_token_by_id(id) do
    if Validator.valid_uuid?(id) do
      ApiToken.Query.by_id(id)
      |> ApiToken.Query.not_expired()
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def new_api_token(attrs \\ %{}) do
    ApiToken.Changeset.changeset(attrs)
  end

  def create_user_api_token(%FzHttp.Users.User{} = user, params) do
    count_by_user_id = count_by_user_id(user.id)
    changeset = ApiToken.Changeset.create_changeset(user, params, max: count_by_user_id)

    with {:ok, api_token} <- Repo.insert(changeset) do
      FzHttp.Telemetry.create_api_token()
      {:ok, api_token}
    end
  end

  def api_token_expired?(%ApiToken{} = api_token) do
    DateTime.diff(api_token.expires_at, DateTime.utc_now()) < 0
  end

  def delete_api_token_by_id(api_token_id, %Users.User{} = user) do
    with {:ok, api_token} <- fetch_api_token_by_id(api_token_id),
         # A user can only delete his/her own MFA method!
         true <- api_token.user_id == user.id do
      {:ok, Repo.delete!(api_token)}
    else
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end
end
