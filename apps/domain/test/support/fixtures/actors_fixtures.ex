defmodule Domain.ActorsFixtures do
  alias Domain.Repo
  alias Domain.Actors
  alias Domain.{AccountsFixtures, AuthFixtures}

  def actor_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      type: :user,
      role: :unprivileged
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
        AuthFixtures.create_email_provider(account: account)
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        AuthFixtures.random_provider_identifier(provider)
      end)

    attrs = actor_attrs(attrs)

    {:ok, actor} = Actors.create_actor(provider, provider_identifier, attrs)
    actor
  end

  def update(actor, updates) do
    actor
    |> Ecto.Changeset.change(Map.new(updates))
    |> Repo.update!()
  end

  def disable(actor) do
    update(actor, %{disabled_at: DateTime.utc_now()})
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
