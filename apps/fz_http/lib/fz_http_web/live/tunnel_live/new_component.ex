defmodule FzHttpWeb.DeviceLive.NewComponent do
  @moduledoc """
  Manages new device modal.
  """
  use FzHttpWeb, :live_component

  alias FzCommon.NameGenerator
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
  def handle_event("create_device", params, socket) do
    case create_device(params, socket) do
      {:not_authorized} ->
        {:noreply, not_authorized(socket)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Error creating tunnel: #{ErrorHelpers.aggregated_errors(changeset)}"
         )}

      {:ok, device} ->
        @events_module.update_device(device)
        {:reply, %{public_key: device.public_key, config: Devices.as_config(device)}, socket}
    end
  end

  defp create_device(%{"user_id" => user_id, "public_key" => public_key} = _params, socket) do
    # Whitelist only name, user_id, public_key
    params = %{
      "user_id" => user_id,
      "public_key" => public_key,
      "name" => NameGenerator.generate()
    }

    if authorized_to_create?(user_id, socket) do
      Devices.create_device(params)
    else
      {:not_authorized}
    end
  end

  defp authorized_to_create?(user_id, socket) do
    "#{socket.assigns.target_user_id}" == "#{user_id}"
  end
end
