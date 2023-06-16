defmodule Domain.ActorsFixtures do
  alias Domain.Repo
  alias Domain.Actors
  alias Domain.{AccountsFixtures, AuthFixtures}

  def actor_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      type: :account_user
    })
  end

  def create_actor(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {provider, attrs} =
      Map.pop_lazy(attrs, :provider, fn ->
        {provider, _bypass} =
          AuthFixtures.start_openid_providers(["google"])
          |> AuthFixtures.create_openid_connect_provider(account: account)

        provider
      end)

    attrs = actor_attrs(attrs)

    Actors.Actor.Changeset.create_changeset(provider, attrs)
    |> Repo.insert!()
  end

  def update(actor, updates) do
    actor
    |> Ecto.Changeset.change(Map.new(updates))
    |> Repo.update!()
  end

  def disable(actor) do
    update(actor, %{disabled_at: DateTime.utc_now()})
  end
end
