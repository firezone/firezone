defmodule FzHttpWeb.DeviceLive.NewFormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Devices
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:device, nil)
     |> assign(:config, nil)}
  end

  @default_fields ~w(
    default_client_mtu
    default_client_endpoint
    default_client_persistent_keepalive
    default_client_dns
    default_client_allowed_ips
  )a
  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    changeset = new_changeset(socket)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(Map.take(FzHttp.Configurations.get_configuration!(), @default_fields))
     |> assign(Devices.defaults(changeset))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"device" => device_params}, socket) do
    changeset =
      device_params
      |> Map.update("dns", nil, &binary_to_list/1)
      |> Map.update("allowed_ips", nil, &binary_to_list/1)
      |> Devices.new_device()

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
      |> Map.update("dns", nil, &binary_to_list/1)
      |> Map.update("allowed_ips", nil, &binary_to_list/1)
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
      (FzHttp.Configurations.get!(:allow_unprivileged_device_management) &&
         socket.assigns.current_user.id == socket.assigns.target_user_id)
  end

  # update/2 is called twice: on load and then connect.
  # Use blank name the first time to prevent flashing two different names in the form.
  # XXX: Clean this up using assign_new/3
  defp new_changeset(socket) do
    if connected?(socket) do
      %{name: FzHttp.Devices.new_name()}
    else
      %{}
    end
    |> Devices.new_device()
  end

  defp binary_to_list(binary) when is_binary(binary),
    do: binary |> String.trim() |> String.split(",")

  defp binary_to_list(list) when is_list(list),
    do: list
end
