defmodule FzHttpWeb.DeviceLive.CreateFormComponent do
  @moduledoc """
  Handles create device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:options_for_select, Users.as_options_for_select())
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"device" => %{"user_id" => user_id}}, socket) do
    case Devices.auto_create_device(%{user_id: user_id}) do
      {:ok, device} ->
        @events_module.update_device(device)

        {:noreply,
         socket
         |> push_redirect(to: Routes.device_show_path(socket, :show, device))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end
end
