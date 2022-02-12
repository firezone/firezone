defmodule FzHttpWeb.DeviceLive.Unprivileged.CreateFormComponent do
  @moduledoc """
  Handles create device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Devices, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:changeset, Devices.new_device())
     |> assign(:options_for_select, Users.as_options_for_select())
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("create_device", %{"device" => device_params}, socket) do
    case Devices.create_device(device_params) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> put_flash(:info, "Device created successfully.")
         |> redirect(to: Routes.device_admin_show_path(socket, :show, device))}

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
