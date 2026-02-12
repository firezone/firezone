defmodule Portal.GatewaySessionFixtures do
  @moduledoc """
  Test helpers for creating gateway sessions.
  """

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.GatewayFixtures
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
      |> Map.put_new(:user_agent, "Linux/6.1.0 connlib/1.3.0 (x86_64)")
      |> Map.put_new(:remote_ip, {100, 64, 0, 1})
      |> Map.put_new(:remote_ip_location_region, "US")
      |> Map.put_new(:version, "1.3.0")

    {:ok, session} =
      %Portal.GatewaySession{}
      |> Ecto.Changeset.cast(session_attrs, [
        :user_agent,
        :remote_ip,
        :remote_ip_location_region,
        :remote_ip_location_city,
        :remote_ip_location_lat,
        :remote_ip_location_lon,
        :version
      ])
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:gateway_id, gateway.id)
      |> Ecto.Changeset.put_change(:gateway_token_id, token.id)
      |> Portal.GatewaySession.changeset()
      |> Portal.Repo.insert()

    session
  end
end
