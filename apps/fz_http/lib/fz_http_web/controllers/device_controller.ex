defmodule FzHttpWeb.DeviceController do
  @moduledoc """
  Entrypoint for Device LiveView
  """
  use FzHttpWeb, :controller

  import FzCommon.FzString, only: [sanitize_filename: 1]
  alias FzHttp.Devices

  plug :redirect_unauthenticated, except: [:config]
  plug :authorize_authenticated, except: [:config]

  def download_config(conn, %{"id" => device_id}) do
    device = Devices.get_device!(device_id)
    render_download(conn, device)
  end

  def download_shared_config(conn, %{"config_token" => config_token}) do
    device = Devices.get_device!(config_token: config_token)
    render_download(conn, device)
  end

  def config(conn, %{"config_token" => config_token}) do
    device = Devices.get_device!(config_token: config_token)

    conn
    |> put_root_layout({FzHttpWeb.LayoutView, "device_config.html"})
    |> render("config.html", config: Devices.as_config(device), device: device)
  end

  defp render_download(conn, device) do
    filename = "#{sanitize_filename(FzHttpWeb.Endpoint.host())}.conf"
    content_type = "text/plain"

    conn
    |> send_download(
      {:binary, Devices.as_config(device)},
      filename: filename,
      content_type: content_type
    )
  end
end
