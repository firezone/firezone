defmodule FzHttpWeb.DeviceController do
  @moduledoc """
  Entrypoint for Device LiveView
  """
  use FzHttpWeb, :controller

  import FzCommon.FzString, only: [sanitize_filename: 1]
  alias FzHttp.Devices

  plug :redirect_unauthenticated

  def index(conn, _params) do
    conn
    |> redirect(to: Routes.device_index_path(conn, :index))
  end

  def download_config(conn, %{"id" => device_id}) do
    device = Devices.get_device!(device_id)
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
