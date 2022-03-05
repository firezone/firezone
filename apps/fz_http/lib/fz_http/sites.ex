defmodule FzHttp.Sites do
  @moduledoc """
  The Sites context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{ConnectivityChecks, Repo, Sites.Site}

  @wg_settings [:allowed_ips, :dns, :endpoint, :persistent_keepalive, :mtu]

  def get_site! do
    get_site!(name: "default")
  end

  def get_site!(name: name) do
    Repo.one!(
      from s in Site,
        where: s.name == ^name
    )
  end

  def get_site!(id) do
    Repo.get!(Site, id)
  end

  def change_site(%Site{} = site) do
    Site.changeset(site, %{})
  end

  def update_site(%Site{} = site, attrs) do
    site
    |> Site.changeset(attrs)
    |> Repo.update()
  end

  def vpn_sessions_expire? do
    freq = vpn_duration()
    freq > 0 && freq < Site.max_vpn_session_duration()
  end

  def vpn_duration do
    get_site!().vpn_session_duration
  end

  def wireguard_defaults do
    site = get_site!()

    @wg_settings
    |> Enum.map(fn s ->
      site_val = Map.get(site, s)

      if is_nil(site_val) do
        {s, default(s)}
      else
        {s, site_val}
      end
    end)
    |> Map.new()
  end

  defp default(:endpoint) do
    app_env(:wireguard_endpoint) || ConnectivityChecks.endpoint()
  end

  defp default(key) do
    app_env(String.to_atom("wireguard_#{key}"))
  end

  defp app_env(key) do
    Application.fetch_env!(:fz_http, key)
  end
end
