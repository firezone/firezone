defmodule Portal.GatewayFixtures do
  @moduledoc """
  Test helpers for creating gateways and related data.
  """

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.DeviceFixtures
  import Portal.TokenFixtures

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
        version: Map.get(session_attrs, :last_seen_version, "1.3.0")
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

  # Private helpers

  defp generate_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp maybe_sync_device_ipv4(device, nil), do: device
  defp maybe_sync_device_ipv4(device, ipv4), do: sync_device_ipv4(device, ipv4)

  defp maybe_sync_device_ipv6(device, nil), do: device
  defp maybe_sync_device_ipv6(device, ipv6), do: sync_device_ipv6(device, ipv6)

  defp extract_address(nil), do: nil
  defp extract_address(%Postgrex.INET{} = address), do: address
  defp extract_address(%{address: %Postgrex.INET{} = address}), do: address
end
