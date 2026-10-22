defmodule Portal.GatewaySessionFixtures do
  @moduledoc """
  Test helpers for recording a gateway connect onto the device's
  latest-session columns. Returns the updated `Portal.Device`.
  """

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.DeviceFixtures
  import Portal.TokenFixtures

  def gateway_session_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    site = Map.get(attrs, :site) || site_fixture(account: account)
    gateway = Map.get(attrs, :gateway) || gateway_fixture(account: account, site: site)
    token = Map.get(attrs, :token) || gateway_token_fixture(account: account, site: site)

    session_attrs =
      attrs
      |> Map.drop([:account, :site, :gateway, :token])
      |> Map.put_new(:public_key, gateway.public_key || generate_public_key())
      |> Map.put_new(:user_agent, "Linux/6.1.0 connlib/1.3.0 (x86_64)")
      |> Map.put_new(:remote_ip, {100, 64, 0, 1})
      |> Map.put_new(:remote_ip_location_region, "US")
      |> Map.put_new(:version, "1.3.0")
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    gateway
    |> Ecto.Changeset.cast(
      %{
        public_key: session_attrs[:public_key],
        last_seen_user_agent: session_attrs[:user_agent],
        last_seen_remote_ip: session_attrs[:remote_ip],
        last_seen_remote_ip_location_region: session_attrs[:remote_ip_location_region],
        last_seen_remote_ip_location_city: session_attrs[:remote_ip_location_city],
        last_seen_remote_ip_location_lat: session_attrs[:remote_ip_location_lat],
        last_seen_remote_ip_location_lon: session_attrs[:remote_ip_location_lon],
        last_seen_version: session_attrs[:version],
        last_seen_at: session_attrs[:inserted_at]
      },
      [
        :public_key,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_version,
        :last_seen_at
      ]
    )
    |> Ecto.Changeset.put_change(:gateway_token_id, token.id)
    |> Portal.Repo.update!()
  end
end
