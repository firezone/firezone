defmodule FzHttpWeb.DeviceLive.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:changeset, Devices.new_device())
     |> assign(:page_title, "Devices")}
  end

  @impl Phoenix.LiveView
  def handle_event("create_device", _params, socket) do
    if Users.count() == 1 do
      # Must be the admin user
      case Devices.auto_create_device(%{user_id: Users.admin().id}) do
        {:ok, device} ->
          @events_module.update_device(device)

          {:noreply,
           socket
           |> push_redirect(to: Routes.device_show_path(socket, :show, device))}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Error creating device: #{ErrorHelpers.aggregated_errors(changeset)}"
           )}
      end
    else
      {:noreply,
       socket
       |> push_patch(to: Routes.device_index_path(socket, :new))}
    end
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_data(_params, socket) do
    # XXX: Update this to use new LiveView session auth
    user = socket.assigns.current_user

    if user.role == :admin do
      assign(socket, :devices, Devices.list_devices())
    else
      not_authorized(socket)
    end
  end
end
