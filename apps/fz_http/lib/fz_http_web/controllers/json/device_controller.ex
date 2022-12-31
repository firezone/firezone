defmodule FzHttpWeb.JSON.DeviceController do
  @moduledoc """
  REST API Controller for Devices.
  """

  use FzHttpWeb, :controller

  action_fallback FzHttpWeb.JSON.FallbackController

  alias FzHttp.Devices

  def index(conn, _params) do
    devices = Devices.list_devices()
    render(conn, "index.json", devices: devices)
  end

  def create(conn, %{"device" => device_params}) do
    with {:ok, device} <- Devices.create_device(device_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/devices/#{device}")
      |> render("show.json", device: device)
    end
  end

  def show(conn, %{"id" => id}) do
    device = Devices.get_device!(id)
    render(conn, "show.json", device: device)
  end

  def update(conn, %{"id" => id, "device" => device_params}) do
    device = Devices.get_device!(id)

    with {:ok, device} <- Devices.update_device(device, device_params) do
      render(conn, "show.json", device: device)
    end
  end

  def delete(conn, %{"id" => id}) do
    device = Devices.get_device!(id)

    with {:ok, _device} <- Devices.delete_device(device) do
      send_resp(conn, :no_content, "")
    end
  end
end
