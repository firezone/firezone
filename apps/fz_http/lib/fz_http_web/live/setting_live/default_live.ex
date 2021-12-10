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
    """
  }

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session)
     |> assign(:help_texts, @help_texts)
     |> assign(:changesets, load_changesets())
     |> assign(:endpoint_placeholder, endpoint_placeholder())
     |> assign(:page_title, "Default Settings")}
  end

  defp endpoint_placeholder do
    ConnectivityChecks.endpoint()
  end

  defp load_changesets do
    Settings.to_list("default.")
    |> Map.new(fn setting -> {setting.key, Settings.change_setting(setting)} end)
  end
end
