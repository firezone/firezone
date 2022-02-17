defmodule FzHttpWeb.DeviceLive.Unprivileged.NewComponent do
  @moduledoc """
  Manages new tunnel modal.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Devices
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Devices.new_device())}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_device", %{"device" => device_params}, socket) do
    new_params = %{device_params | "user_id" => socket.assigns.current_user.id}

    case Devices.create_device(new_params) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> put_flash(:info, "Tunnel added successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Error creating device: #{ErrorHelpers.aggregated_errors(changeset)}"
         )}
    end
  end
end
