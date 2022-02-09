defmodule FzHttpWeb.SettingLive.Site do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{ConnectivityChecks, Sites}

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)}
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

  defp load_data(_params, socket) do
    user = socket.assigns.current_user
    changeset = Sites.get_site!() |> Sites.change_site()

    placeholders = %{
      allowed_ips: allowed_ips_placeholder(),
      dns: dns_placeholder(),
      persistent_keepalive: persistent_keepalive_placeholder(),
      endpoint: endpoint_placeholder(),
      mtu: mtu_placeholder()
    }

    if user.role == :admin do
      socket
      |> assign(:changeset, changeset)
      |> assign(:placeholders, placeholders)
      |> assign(:page_title, "Site Settings")
    else
      not_authorized(socket)
    end
  end
end
