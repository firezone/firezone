defmodule Domain.Fixtures.Clients do
  use Domain.Fixture
  alias Domain.Clients

  def client_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name: "client-#{unique_integer()}",
      public_key: unique_public_key(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/1.3.0",
      last_seen_remote_ip: Enum.random([unique_ipv4(), unique_ipv6()]),
      last_seen_remote_ip_location_region: "US",
      last_seen_remote_ip_location_city: "San Francisco",
      last_seen_remote_ip_location_lat: 37.7758,
      last_seen_remote_ip_location_lon: -122.4128,
      device_serial: Ecto.UUID.generate(),
      device_uuid: Ecto.UUID.generate(),
      identifier_for_vendor: Ecto.UUID.generate(),
      firebase_installation_id: Ecto.UUID.generate()
    })
  end

  def create_client(attrs \\ %{}) do
    attrs = client_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        if relation = attrs[:actor] || attrs[:identity] do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          Fixtures.Accounts.create_account(assoc_attrs)
        end
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :service_account, account: account})
        |> Fixtures.Actors.create_actor()
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: actor})
        |> Fixtures.Auth.create_identity()
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          identity: identity,
          actor: [type: :account_admin_user]
        })
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, client} = Clients.upsert_client(attrs, subject)
    %{client | online?: false}
  end

  def delete_client(client) do
    client = Repo.preload(client, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: client.account,
        actor: [type: :account_admin_user]
      )

    {:ok, client} = Clients.delete_client(client, subject)
    client
  end

  def verify_client(client) do
    client = Repo.preload(client, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: client.account,
        actor: [type: :account_admin_user]
      )

    {:ok, client} = Clients.verify_client(client, subject)
    client
  end
end
