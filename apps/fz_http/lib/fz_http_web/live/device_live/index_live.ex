defmodule FzHttpWeb.DeviceLive.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Devices
  alias FzHttpWeb.ErrorHelpers

  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:page_title, "All Devices")}
  end

  def handle_event("create_device", _params, socket) do
    {:ok, privkey, pubkey, server_pubkey} = @events_module.create_device()

    attributes = %{
      private_key: privkey,
      public_key: pubkey,
      server_public_key: server_pubkey,
      user_id: socket.assigns.current_user.id,
      name: Devices.rand_name()
    }

    case Devices.create_device(attributes) do
      {:ok, device} ->
        @events_module.device_created(device)

        {:noreply,
         socket
         |> redirect(to: Routes.device_show_path(socket, :show, device))}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Error creating device: #{ErrorHelpers.aggregated_errors(changeset)}"
         )}
    end
  end

  defp load_data(_params, socket) do
    assign(socket, :devices, Devices.list_devices())
  end
end
