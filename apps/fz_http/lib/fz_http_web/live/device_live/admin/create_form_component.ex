defmodule FzHttpWeb.DeviceLive.Admin.CreateFormComponent do
  @moduledoc """
  Allows Admins to create devices for users.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Devices, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:changeset, Devices.new_device(%{user_id: assigns.target_user_id}))
     |> assign(:options_for_select, Users.as_options_for_select())
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_device", %{"device" => device_params}, socket) do
    create_device(device_params, socket)
  end

  defp create_device(device_params, socket) do
    case Devices.create_device(device_params) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> put_flash(:info, "Device created successfully.")
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
