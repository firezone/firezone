defmodule Portal.ClientFixtures do
  @moduledoc """
  Test helpers for creating clients and related data.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IPv4AddressFixtures
  import Portal.IPv6AddressFixtures

  @doc """
  Generate valid client attributes with sensible defaults.
  """
  def valid_client_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Client #{unique_num}",
      external_id: "client_#{unique_num}",
      device_serial: "SN#{unique_num}",
      device_uuid: "UUID-#{unique_num}",
      firebase_installation_id: "firebase_#{unique_num}"
    })
  end

  @doc """
  Generate a client with valid default attributes.

  The client will be created with an associated account and actor unless they are provided.

  ## Examples

      client = client_fixture()
      client = client_fixture(name: "My Laptop")
      client = client_fixture(actor: actor)

  """
  def client_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create actor
    actor = Map.get(attrs, :actor) || actor_fixture(account: account)

    # Build client attrs
    client_attrs =
      attrs
      |> Map.drop([:account, :actor, :ipv4_address, :ipv6_address])
      |> valid_client_attrs()

    {:ok, client} =
      %Portal.Client{}
      |> Ecto.Changeset.cast(client_attrs, [
        :name,
        :external_id,
        :device_serial,
        :device_uuid,
        :identifier_for_vendor,
        :firebase_installation_id,
        :verified_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Portal.Client.changeset()
      |> Portal.Repo.insert()

    # Create address records for the client (unless explicitly set to nil)
    Map.get_lazy(attrs, :ipv4_address, fn -> ipv4_address_fixture(client: client) end)
    Map.get_lazy(attrs, :ipv6_address, fn -> ipv6_address_fixture(client: client) end)

    # Return client with addresses preloaded
    Portal.Repo.preload(client, [:ipv4_address, :ipv6_address])
  end

  @doc """
  Generate a verified client.
  """
  def verified_client_fixture(attrs \\ %{}) do
    client_fixture(Map.put(attrs, :verified_at, DateTime.utc_now()))
  end

  @doc """
  Generate a client (same as client_fixture, kept for compatibility).
  """
  def online_client_fixture(attrs \\ %{}) do
    client_fixture(attrs)
  end

  @doc """
  Generate a client with device identifiers.
  """
  def client_with_device_ids_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Map.put_new(:device_serial, "SN#{unique_num}")
      |> Map.put_new(:device_uuid, "UUID-#{unique_num}")
      |> Map.put_new(:identifier_for_vendor, "IFV-#{unique_num}")

    client_fixture(attrs)
  end

  @doc """
  Generate a mobile client with Firebase installation ID.
  """
  def mobile_client_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Map.put_new(:firebase_installation_id, "firebase_#{unique_num}")

    client_fixture(attrs)
  end

  @doc """
  Create multiple clients for the same actor.
  """
  def actor_clients_fixture(actor, count \\ 3, attrs \\ %{}) do
    account = actor.account || Portal.Repo.preload(actor, :account).account

    for _ <- 1..count do
      client_fixture(Map.merge(attrs, %{actor: actor, account: account}))
    end
  end

  @doc """
  Verify a client (sets verified_at timestamp).
  """
  def verify_client(client) do
    client
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now())
    |> Portal.Repo.update!()
  end

  @doc """
  Generate a random WireGuard public key for tests.
  """
  def generate_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end
end
