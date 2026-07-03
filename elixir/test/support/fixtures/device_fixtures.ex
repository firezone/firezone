defmodule Portal.DeviceFixtures do
  @moduledoc """
  Test helpers for creating client and gateway devices and related data.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  ##############################################################################
  # Address helpers shared by client and gateway fixtures
  ##############################################################################

  def valid_ipv4_address_attrs do
    offset = System.unique_integer([:positive, :monotonic])
    third = rem(div(offset, 256), 32)
    fourth = rem(offset, 256)
    fourth = if fourth < 2, do: fourth + 2, else: fourth

    %{
      address: %Postgrex.INET{address: {100, 64, third, fourth}}
    }
  end

  def valid_ipv6_address_attrs do
    offset = System.unique_integer([:positive, :monotonic])
    w7 = rem(div(offset, 65_536), 65_536)
    w8 = rem(offset, 65_536)
    w8 = if w8 < 2, do: w8 + 2, else: w8

    %{
      address: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, w7, w8}}
    }
  end

  def sync_device_ipv4(%Portal.Device{} = device, %Postgrex.INET{} = address) do
    Portal.Repo.update!(Ecto.Changeset.change(device, ipv4: address))
  end

  def sync_device_ipv6(%Portal.Device{} = device, %Postgrex.INET{} = address) do
    Portal.Repo.update!(Ecto.Changeset.change(device, ipv6: address))
  end

  @doc """
  Returns the device row used by channel and API tests.
  """
  def fetch_device!(%Portal.Device{} = device), do: device

  @doc """
  Generate a random WireGuard public key for tests.
  """
  def generate_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  ##############################################################################
  # Client devices
  ##############################################################################

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
  Build an unpersisted client `Device` changeset with the given attrs cast against a
  random `actor_id` (so `:client`-type validations pass). Useful for asserting
  `errors_on/1` without round-tripping the database.
  """
  def client_changeset(attrs \\ %{}) do
    %Portal.Device{type: :client, actor_id: Ecto.UUID.generate()}
    |> Ecto.Changeset.cast(attrs, [:name, :firezone_id, :hostname])
    |> Portal.Device.changeset()
  end

  @doc """
  Attempt to insert a client device with the given attrs against a real account + actor.
  Returns the raw `{:ok, device} | {:error, changeset}` so tests can pattern-match
  constraint failures (e.g. unique index violations) without relying on bang variants
  raising.
  """
  def insert_client(account, actor, attrs) do
    %Portal.Device{}
    |> Ecto.Changeset.cast(attrs, [:name, :firezone_id, :hostname])
    |> Ecto.Changeset.put_change(:type, :client)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Ecto.Changeset.put_change(:actor_id, actor.id)
    |> Portal.Device.changeset()
    |> Portal.Repo.insert()
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
        :hostname,
        :verified_at
      ])
      |> Ecto.Changeset.put_change(:type, :client)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:actor_id, actor.id)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Portal.Device.changeset()
      |> Portal.Repo.insert()

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

  ##############################################################################
  # Gateway devices
  ##############################################################################

  @doc """
  Generate valid gateway attributes with sensible defaults.
  """
  def valid_gateway_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Gateway #{unique_num}",
      firezone_id: "gateway_#{unique_num}",
      public_key: generate_public_key()
    })
  end

  @doc """
  Generate a gateway with valid default attributes.

  The gateway will be created with an associated account and site unless they are provided.

  ## Examples

      gateway = gateway_fixture()
      gateway = gateway_fixture(name: "Production Gateway")
      gateway = gateway_fixture(site: site)

  """
  def gateway_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create site
    site = Map.get(attrs, :site) || site_fixture(account: account)

    # Extract session-related attrs
    session_attrs =
      Map.take(attrs, [
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_version,
        :last_seen_at
      ])

    device_attrs =
      attrs
      |> Map.drop([
        :account,
        :site,
        :ipv4_address,
        :ipv6_address,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_version,
        :last_seen_at
      ])
      |> valid_gateway_attrs()

    {:ok, gateway} =
      %Portal.Device{}
      |> Ecto.Changeset.cast(device_attrs, [
        :name,
        :firezone_id
      ])
      |> Ecto.Changeset.put_change(:type, :gateway)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:site_id, site.id)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:site, site)
      |> Portal.Device.changeset()
      |> Portal.Repo.insert()

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

    gateway =
      gateway
      |> maybe_sync_device_ipv4(ipv4)
      |> maybe_sync_device_ipv6(ipv6)

    # Always create a gateway session (gateways always have sessions in practice)
    token = gateway_token_fixture(account: account, site: site)

    public_key = Map.get(device_attrs, :public_key, generate_public_key())

    session =
      %Portal.GatewaySession{
        account_id: account.id,
        device_id: gateway.id,
        gateway_token_id: token.id,
        public_key: public_key,
        user_agent: Map.get(session_attrs, :last_seen_user_agent, "Firezone-Gateway/1.3.0"),
        remote_ip: Map.get(session_attrs, :last_seen_remote_ip, {100, 64, 0, 1}),
        remote_ip_location_region: Map.get(session_attrs, :last_seen_remote_ip_location_region),
        remote_ip_location_city: Map.get(session_attrs, :last_seen_remote_ip_location_city),
        remote_ip_location_lat: Map.get(session_attrs, :last_seen_remote_ip_location_lat),
        remote_ip_location_lon: Map.get(session_attrs, :last_seen_remote_ip_location_lon),
        version: Map.get(session_attrs, :last_seen_version, "1.3.0"),
        timestamp: DateTime.utc_now()
      }
      |> Portal.Repo.insert!()

    # Return gateway with addresses preloaded and latest session set
    gateway
    |> Portal.Repo.preload(:site)
    |> Map.put(:latest_session, session)
  end

  @doc """
  Generate an online gateway with last seen information.
  """
  def online_gateway_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Firezone-Gateway/1.0.0")
      |> Map.put_new(:last_seen_version, "1.0.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})

    gateway_fixture(attrs)
  end

  @doc """
  Generate a gateway with location information.
  """
  def gateway_with_location_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Firezone-Gateway/1.3.0")
      |> Map.put_new(:last_seen_version, "1.3.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})
      |> Map.put_new(:last_seen_remote_ip_location_region, "US-CA")
      |> Map.put_new(:last_seen_remote_ip_location_city, "San Francisco")
      |> Map.put_new(:last_seen_remote_ip_location_lat, 37.7749)
      |> Map.put_new(:last_seen_remote_ip_location_lon, -122.4194)

    gateway_fixture(attrs)
  end

  @doc """
  Create multiple gateways for the same site.
  """
  def site_gateways_fixture(site, count \\ 3, attrs \\ %{}) do
    account = site.account || Portal.Repo.preload(site, :account).account

    for _ <- 1..count do
      gateway_fixture(Map.merge(attrs, %{site: site, account: account}))
    end
  end

  ##############################################################################
  # Private helpers
  ##############################################################################

  defp maybe_sync_device_ipv4(device, nil), do: device
  defp maybe_sync_device_ipv4(device, ipv4), do: sync_device_ipv4(device, ipv4)

  defp maybe_sync_device_ipv6(device, nil), do: device
  defp maybe_sync_device_ipv6(device, ipv6), do: sync_device_ipv6(device, ipv6)

  defp extract_address(nil), do: nil
  defp extract_address(%Postgrex.INET{} = address), do: address
  defp extract_address(%{address: %Postgrex.INET{} = address}), do: address
end
