defmodule Domain.ClientsFixtures do
  alias Domain.Repo
  alias Domain.Clients
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  def client_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name: "client-#{counter()}",
      public_key: public_key()
    })
  end

  def create_client(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        if relation = attrs[:actor] || attrs[:identity] do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          AccountsFixtures.create_account()
        end
      end)

    {actor, attrs} =
      Map.pop_lazy(attrs, :actor, fn ->
        ActorsFixtures.create_actor(role: :admin, account: account)
      end)

    {identity, attrs} =
      Map.pop_lazy(attrs, :identity, fn ->
        AuthFixtures.create_identity(account: account, actor: actor)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        AuthFixtures.create_subject(identity)
      end)

    attrs = client_attrs(attrs)

    {:ok, client} = Clients.upsert_client(attrs, subject)
    client
  end

  def delete_client(client) do
    client = Repo.preload(client, :account)
    actor = ActorsFixtures.create_actor(role: :admin, account: client.account)
    identity = AuthFixtures.create_identity(account: client.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, client} = Clients.delete_client(client, subject)
    client
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
