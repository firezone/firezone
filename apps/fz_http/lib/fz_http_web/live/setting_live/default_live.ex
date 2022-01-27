defmodule FzHttpWeb.SettingLive.Default do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{ConnectivityChecks, Settings}

  @help_texts %{
    allowed_ips: """
      Configures the default AllowedIPs setting for devices.
      AllowedIPs determines which destination IPs get routed through
      Firezone. Specify a comma-separated list of IPs or CIDRs here to achieve split tunneling, or use
      <code>0.0.0.0/0, ::/0</code> to route all device traffic through this Firezone server.
    """,
    dns_servers: """
      Comma-separated list of DNS servers to use for devices.
      Leaving this blank will omit the <code>DNS</code> section in
      generated device configs.
    """,
    endpoint: """
      IPv4 or IPv6 address that devices will be configured to connect
      to. Defaults to this server's public IP if not set.
    """,
    persistent_keepalive: """
      Interval in seconds to send persistent keepalive packets. Most users won't need to change
      this. Set to 0 or leave blank to disable. Leave this blank if you're unsure what this means.
    """,
    mtu: """
      WireGuard interface MTU for devices. Defaults to what's set in the configuration file.
      Leave this blank if you're unsure what this means.
    """
  }

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

  defp load_changesets do
    Settings.to_list("default.")
    |> Map.new(fn setting -> {setting.key, Settings.change_setting(setting)} end)
  end

  defp load_data(_params, socket) do
    user = socket.assigns.current_user

    if user.role == :admin do
      socket
      |> assign(:changesets, load_changesets())
      |> assign(:help_texts, @help_texts)
      |> assign(:endpoint_placeholder, endpoint_placeholder())
      |> assign(:mtu_placeholder, mtu_placeholder())
      |> assign(:dns_placeholder, dns_placeholder())
      |> assign(:allowed_ips_placeholder, allowed_ips_placeholder())
      |> assign(:persistent_keepalive_placeholder, persistent_keepalive_placeholder())
      |> assign(:page_title, "Default Settings")
    else
      not_authorized(socket)
    end
  end
end
