defmodule FzHttp.ApiTokensFixtures do
  alias FzHttp.UsersFixtures

  def api_token_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{})
  end

  def create_api_token(attrs \\ %{}) do
    attrs = api_token_attrs(attrs)
    {user, attrs} = Map.pop_lazy(attrs, :user, fn -> UsersFixtures.user() end)
    {:ok, api_token} = FzHttp.ApiTokens.create_user_api_token(user, attrs)
    api_token
  end

  def expire_api_token(api_token) do
    one_second_ago = DateTime.utc_now() |> DateTime.add(-1, :second)

    Ecto.Changeset.change(api_token, expires_at: one_second_ago)
    |> FzHttp.Repo.update!()
  end
end
