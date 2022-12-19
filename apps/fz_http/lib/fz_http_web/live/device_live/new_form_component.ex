defmodule FzHttpWeb.DeviceLive.NewFormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Configurations, as: Conf
  alias FzHttp.Devices
  alias FzHttp.Sites
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:device, nil)
     |> assign(:config, nil)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    changeset = new_changeset(socket)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(
       Map.take(Sites.get_site!(), [:mtu, :endpoint, :persistent_keepalive, :dns, :allowed_ips])
     )
     |> assign(Devices.defaults(changeset))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"device" => device_params}, socket) do
    changeset = Devices.new_device(device_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(Devices.defaults(changeset))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"device" => device_params}, socket) do
    result =
      device_params
      |> Map.put("user_id", socket.assigns.target_user_id)
      |> create_device(socket)

    case result do
      :not_authorized ->
        {:noreply, not_authorized(socket)}

      {:ok, device} ->
        send_update(FzHttpWeb.ModalComponent, id: :modal, hide_footer_content: true)

        {:noreply,
         socket
         |> assign(:device, device)
         |> assign(:config, Devices.as_encoded_config(device))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, ErrorHelpers.aggregated_errors(changeset))
         |> assign(:changeset, changeset)}
    end
  end

  defp create_device(params, socket) do
    if authorized_to_create?(socket) do
      Devices.create_device(params)
    else
      :not_authorized
    end
  end

  defp authorized_to_create?(socket) do
    has_role?(socket, :admin) ||
      (Conf.get!(:allow_unprivileged_device_management) &&
         to_string(socket.assigns.current_user.id) == to_string(socket.assigns.target_user_id))
  end

  # update/2 is called twice: on load and then connect.
  # Use blank name the first time to prevent flashing two different names in the form.
  # XXX: Clean this up using assign_new/3
  defp new_changeset(socket) do
    if connected?(socket) do
      Devices.new_device()
    else
      Devices.new_device(%{"name" => nil})
    end
  end
end
