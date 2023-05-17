defmodule Domain.ApiTokensFixtures do
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  def api_token_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{})
  end

  def create_api_token(attrs \\ %{}) do
    attrs = api_token_attrs(attrs)

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        actor = ActorsFixtures.create_actor(role: :admin, account: account)
        identity = AuthFixtures.create_identity(account: account, actor: actor)
        AuthFixtures.create_subject(identity)
      end)

    {:ok, api_token} = Domain.ApiTokens.create_api_token(attrs, subject)
    api_token
  end

  def expire_api_token(api_token) do
    one_second_ago = DateTime.utc_now() |> DateTime.add(-1, :second)

    Ecto.Changeset.change(api_token, expires_at: one_second_ago)
    |> Domain.Repo.update!()
  end
end
