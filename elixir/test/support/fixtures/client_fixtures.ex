defmodule Portal.ClientFixtures do
  @moduledoc """
  Test helpers for creating clients and related data.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures

  @doc """
  Generate valid client attributes with sensible defaults.
  """
  def valid_client_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Client #{unique_num}",
      firezone_id: "client_#{unique_num}",
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

    device_attrs =
      attrs
      |> Map.drop([:account, :actor, :ipv4_address, :ipv6_address])
      |> valid_client_attrs()

    {:ok, device} =
      %Portal.Device{}
      |> Ecto.Changeset.cast(device_attrs, [
        :name,
        :firezone_id,
        :device_serial,
        :device_uuid,
        :identifier_for_vendor,
        :firebase_installation_id,
        :verified_at
      ])
      |> Ecto.Changeset.put_change(:type, :client)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:actor_id, actor.id)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Portal.Device.changeset()
      |> Portal.Safe.unscoped()
      |> Portal.Safe.insert()

    ipv4 =
      attrs
      |> Map.fetch(:ipv4_address)
      |> case do
        {:ok, value} -> extract_address(value)
        :error -> valid_ipv4_address_attrs().address
      end

    ipv6 =
      attrs
      |> Map.fetch(:ipv6_address)
      |> case do
        {:ok, value} -> extract_address(value)
        :error -> valid_ipv6_address_attrs().address
      end

    device =
      device
      |> maybe_sync_device_ipv4(ipv4)
      |> maybe_sync_device_ipv6(ipv6)

    Portal.Repo.preload(device, :actor)
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

  defp maybe_sync_device_ipv4(device, nil), do: device
  defp maybe_sync_device_ipv4(device, ipv4), do: sync_device_ipv4(device, ipv4)

  defp maybe_sync_device_ipv6(device, nil), do: device
  defp maybe_sync_device_ipv6(device, ipv6), do: sync_device_ipv6(device, ipv6)

  defp extract_address(nil), do: nil
  defp extract_address(%Postgrex.INET{} = address), do: address
  defp extract_address(%{address: %Postgrex.INET{} = address}), do: address

  @doc """
  Generate a random WireGuard public key for tests.
  """
  def generate_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end
end
