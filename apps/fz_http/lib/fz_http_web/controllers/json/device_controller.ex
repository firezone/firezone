defmodule FzHttpWeb.JSON.DeviceController do
  @moduledoc api_doc: [title: "Devices", group: "Devices"]
  @moduledoc """
  This endpoint allows an administrator to manage Devices.
  """
  use FzHttpWeb, :controller
  alias FzHttp.{Users, Devices}
  alias FzHttpWeb.Auth.JSON.Authentication

  action_fallback(FzHttpWeb.JSON.FallbackController)

  @doc api_doc: [summary: "List all Devices"]
  def index(conn, _attrs) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, devices} <- Devices.list_devices(subject) do
      defaults = Devices.defaults()
      render(conn, "index.json", devices: devices, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Create a Device"]
  def create(conn, %{"device" => attrs}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, user} <- Users.fetch_user_by_id(attrs["user_id"], subject),
         {:ok, device} <- Devices.create_device_for_user(user, attrs, subject) do
      defaults = Devices.defaults()

      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/devices/#{device}")
      |> render("show.json", device: device, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Get Device by ID"]
  def show(conn, %{"id" => id}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, device} <- Devices.fetch_device_by_id(id, subject) do
      defaults = Devices.defaults()
      render(conn, "show.json", device: device, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Update a Device"]
  def update(conn, %{"id" => id, "device" => attrs}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, device} <- Devices.fetch_device_by_id(id, subject),
         {:ok, device} <- Devices.update_device(device, attrs, subject) do
      defaults = Devices.defaults()
      render(conn, "show.json", device: device, defaults: defaults)
    end
  end

  @doc api_doc: [summary: "Delete a Device"]
  def delete(conn, %{"id" => id}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, device} <- Devices.fetch_device_by_id(id, subject),
         {:ok, _device} <- Devices.delete_device(device, subject) do
      send_resp(conn, :no_content, "")
    end
  end
end
