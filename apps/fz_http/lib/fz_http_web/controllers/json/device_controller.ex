defmodule FzHttpWeb.JSON.DeviceController do
  @moduledoc api_doc: [title: "Devices", group: "Devices"]
  @moduledoc """
  This endpoint allows an administrator to manage Devices.
  """

  use FzHttpWeb, :controller

  action_fallback(FzHttpWeb.JSON.FallbackController)

  alias FzHttp.Devices

  @doc api_doc: [summary: "List all Devices"]
  def index(conn, _params) do
    devices = Devices.list_devices()
    defaults = Devices.defaults()
    render(conn, "index.json", devices: devices, defaults: defaults)
  end

  @doc api_doc: [summary: "Create a Device"]
  def create(conn, %{"device" => device_params}) do
    with {:ok, device} <- Devices.create_device(device_params) do
      defaults = Devices.defaults()

      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/devices/#{device}")
      |> render("show.json", device: device, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Get Device by ID"]
  def show(conn, %{"id" => id}) do
    device = Devices.get_device!(id)
    defaults = Devices.defaults()
    render(conn, "show.json", device: device, defaults: defaults)
  end

  @doc api_doc: [summary: "Update a Device"]
  def update(conn, %{"id" => id, "device" => device_params}) do
    device = Devices.get_device!(id)

    with {:ok, device} <- Devices.update_device(device, device_params) do
      defaults = Devices.defaults()
      render(conn, "show.json", device: device, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Delete a Device"]
  def delete(conn, %{"id" => id}) do
    device = Devices.get_device!(id)

    with {:ok, _device} <- Devices.delete_device(device) do
      send_resp(conn, :no_content, "")
    end
  end
end
