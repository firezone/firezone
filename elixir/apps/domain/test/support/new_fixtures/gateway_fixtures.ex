defmodule Domain.GatewayFixtures do
  @moduledoc """
  Test helpers for creating gateways and related data.
  """

  import Domain.AccountFixtures
  import Domain.SiteFixtures
  import Domain.NetworkAddressFixtures

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

    # Create network addresses for IPv4 and IPv6 if not provided
    ipv4_address =
      if Map.has_key?(attrs, :ipv4) do
        Map.get(attrs, :ipv4)
      else
        ipv4_network_address_fixture(account: account)
      end

    ipv6_address =
      if Map.has_key?(attrs, :ipv6) do
        Map.get(attrs, :ipv6)
      else
        ipv6_network_address_fixture(account: account)
      end

    # Build gateway attrs
    gateway_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:site)
      |> Map.delete(:ipv4)
      |> Map.delete(:ipv6)
      |> valid_gateway_attrs()

    {:ok, gateway} =
      %Domain.Gateway{}
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
      |> Ecto.Changeset.put_change(:ipv4, ipv4_address.address)
      |> Ecto.Changeset.put_change(:ipv6, ipv6_address.address)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:site, site)
      |> Domain.Gateway.changeset()
      |> Domain.Repo.insert()

    gateway
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
    account = site.account || Domain.Repo.preload(site, :account).account

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
