defmodule FgHttpWeb.DeviceController do
  @moduledoc """
  Implements the CRUD for a Device
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Devices, Rules}
  alias FgHttpWeb.ErrorHelpers
  require Logger

  plug FgHttpWeb.Plugs.SessionLoader

  def index(conn, _params) do
    devices = Devices.list_devices(conn.assigns.session.id, :with_rules)
    render(conn, "index.html", devices: devices)
  end

  def create(conn, _params) do
    # XXX: Remove device from WireGuard if create isn't successful
    {:ok, privkey, pubkey, server_pubkey, psk} = @events_module.create_device()

    device_attrs = %{
      private_key: privkey,
      public_key: pubkey,
      server_public_key: server_pubkey,
      preshared_key: psk
    }

    attributes =
      Map.merge(%{user_id: conn.assigns.session.id, name: Devices.rand_name()}, device_attrs)

    case Devices.create_device(attributes) do
      {:ok, device} ->
        redirect(conn, to: Routes.device_path(conn, :show, device))

      {:error, %Ecto.Changeset{} = changeset} ->
        msg = ErrorHelpers.aggregated_errors(changeset)

        conn
        |> put_flash(:error, "Error creating device. #{msg}")
        |> redirect(to: Routes.device_path(conn, :index))
    end
  end

  def show(conn, %{"id" => id}) do
    device = Devices.get_device!(id)
    rule_changeset = Rules.new_rule(%{"device_id" => id})
    whitelist = Rules.whitelist(device)
    blacklist = Rules.blacklist(device)

    render(conn, "show.html",
      device: device,
      whitelist: whitelist,
      blacklist: blacklist,
      rule_changeset: rule_changeset
    )
  end

  def delete(conn, %{"id" => id}) do
    device = Devices.get_device!(id)

    case Devices.delete_device(device) do
      {:ok, _deleted_device} ->
        {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

        conn
        |> put_flash(:info, "Device deleted successfully.")
        |> redirect(to: Routes.device_path(conn, :index))

      {:error, msg} ->
        conn
        |> put_flash(:error, "Error deleting device: #{msg}")
        |> redirect(to: Routes.device_path(conn, :index))
    end
  end
end
