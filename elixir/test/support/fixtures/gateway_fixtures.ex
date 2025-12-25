defmodule Portal.GatewayFixtures do
  @moduledoc """
  Test helpers for creating gateways and related data.
  """

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.IPv4AddressFixtures
  import Portal.IPv6AddressFixtures

  @doc """
  Generate valid gateway attributes with sensible defaults.
  """
  def valid_gateway_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Gateway #{unique_num}",
      external_id: "gateway_#{unique_num}",
      public_key: generate_public_key(),
      last_seen_user_agent: "Firezone-Gateway/1.3.0",
      last_seen_remote_ip: {100, 64, 0, 1},
      # Version 1.3.0+ is required for internet resources
      last_seen_version: "1.3.0",
      last_seen_at: DateTime.utc_now()
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

    # Build gateway attrs
    gateway_attrs =
      attrs
      |> Map.drop([:account, :site, :ipv4_address, :ipv6_address])
      |> valid_gateway_attrs()

    {:ok, gateway} =
      %Portal.Gateway{}
      |> Ecto.Changeset.cast(gateway_attrs, [
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
        :last_seen_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:site, site)
      |> Portal.Gateway.changeset()
      |> Portal.Repo.insert()

    # Create address records for the gateway (unless explicitly set to nil)
    Map.get_lazy(attrs, :ipv4_address, fn -> ipv4_address_fixture(gateway: gateway) end)
    Map.get_lazy(attrs, :ipv6_address, fn -> ipv6_address_fixture(gateway: gateway) end)

    # Return gateway with addresses preloaded
    Portal.Repo.preload(gateway, [:ipv4_address, :ipv6_address])
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
end
