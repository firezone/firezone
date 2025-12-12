defmodule Domain.ClientFixtures do
  @moduledoc """
  Test helpers for creating clients and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures

  @doc """
  Generate valid client attributes with sensible defaults.
  """
  def valid_client_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Client #{unique_num}",
      external_id: "client_#{unique_num}",
      public_key: generate_public_key(),
      # User agent format: "OS_Name/OS_Version Client_Type/Client_Version"
      # NOTE: The version in the user agent must match last_seen_version
      # because the gateway view re-parses the version from the user agent
      last_seen_user_agent: "macOS/14.0 apple-client/1.3.0",
      last_seen_remote_ip: {100, 64, 0, 1},
      last_seen_remote_ip_location_region: "US",
      last_seen_version: "1.3.0",
      last_seen_at: DateTime.utc_now()
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
      |> Map.delete(:account)
      |> Map.delete(:actor)
      |> valid_client_attrs()

    {:ok, client} =
      %Domain.Client{}
      |> Ecto.Changeset.cast(client_attrs, [
        :name,
        :external_id,
        :public_key,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_version,
        :last_seen_at,
        :device_serial,
        :device_uuid,
        :identifier_for_vendor,
        :firebase_installation_id,
        :verified_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Domain.Client.changeset()
      |> Domain.Repo.insert()

    client
  end

  @doc """
  Generate a verified client.
  """
  def verified_client_fixture(attrs \\ %{}) do
    client_fixture(Map.put(attrs, :verified_at, DateTime.utc_now()))
  end

  @doc """
  Generate a client with last seen information.
  """
  def online_client_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Firezone/1.0.0")
      |> Map.put_new(:last_seen_version, "1.0.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})

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
      |> Map.put_new(:last_seen_user_agent, "Firezone-Android/1.0.0")

    client_fixture(attrs)
  end

  @doc """
  Create multiple clients for the same actor.
  """
  def actor_clients_fixture(actor, count \\ 3, attrs \\ %{}) do
    account = actor.account || Domain.Repo.preload(actor, :account).account

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
    |> Domain.Repo.update!()
  end

  # Private helpers

  defp generate_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end
end
