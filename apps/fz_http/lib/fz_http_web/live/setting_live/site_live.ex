defmodule FzHttpWeb.SettingLive.Site do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{ConnectivityChecks, Sites}

  @page_title "Site Settings"
  @page_subtitle "Configure default WireGuard settings for this site."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:changeset, changeset())
     |> assign(:placeholders, placeholders())
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  defp endpoint_placeholder do
    ConnectivityChecks.endpoint()
  end

  defp mtu_placeholder do
    Application.fetch_env!(:fz_http, :wireguard_mtu)
  end

  defp dns_placeholder do
    Application.fetch_env!(:fz_http, :wireguard_dns)
  end

  defp allowed_ips_placeholder do
    Application.fetch_env!(:fz_http, :wireguard_allowed_ips)
  end

  defp persistent_keepalive_placeholder do
    Application.fetch_env!(:fz_http, :wireguard_persistent_keepalive)
  end

  defp placeholders do
    %{
      allowed_ips: allowed_ips_placeholder(),
      dns: dns_placeholder(),
      persistent_keepalive: persistent_keepalive_placeholder(),
      endpoint: endpoint_placeholder(),
      mtu: mtu_placeholder()
    }
  end

  defp changeset do
    Sites.get_site!() |> Sites.change_site()
  end
end
