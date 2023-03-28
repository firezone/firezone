defmodule FzHttpWeb.DeviceLive.NewFormComponent do
  @moduledoc """
  Handles device form.
  """
  use FzHttpWeb, :live_component
  alias FzHttp.Devices
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    socket =
      socket
      |> assign(:device, nil)
      |> assign(:config, nil)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    changeset = Devices.new_device()

    config =
      FzHttp.Config.fetch_source_and_configs!(~w(
        default_client_mtu
        default_client_endpoint
        default_client_persistent_keepalive
        default_client_dns
        default_client_allowed_ips
      )a)
      |> Enum.into(%{}, fn {k, {_s, v}} -> {k, v} end)

    socket =
      socket
      |> assign(assigns)
      |> assign(config)
      |> assign_new(:changeset, fn -> changeset end)
      |> assign(use_default_fields(changeset))

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"device" => device_params}, socket) do
    attrs =
      device_params
      |> Map.update("dns", nil, &binary_to_list/1)
      |> Map.update("allowed_ips", nil, &binary_to_list/1)

    # Note: change_device is used here because when you type in at some point
    # the input can be empty while you typing, which will immediately put back
    # an new default value from the changeset.
    changeset = Devices.change_device(%Devices.Device{}, attrs)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(use_default_fields(changeset))

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"device" => device_params}, socket) do
    device_params
    |> Map.update("dns", nil, &binary_to_list/1)
    |> Map.update("allowed_ips", nil, &binary_to_list/1)
    |> create_device(socket)
    |> case do
      {:ok, device} ->
        send_update(FzHttpWeb.ModalComponent, id: :modal, hide_footer_content: true)

        device_config =
          FzHttpWeb.WireguardConfigView.render("base64_device.conf", %{device: device})

        socket =
          socket
          |> assign(:device, device)
          |> assign(:config, device_config)

        {:noreply, socket}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, ErrorHelpers.aggregated_errors(changeset))
         |> assign(:changeset, changeset)}
    end
  end

  defp use_default_fields(changeset) do
    ~w(
      use_default_allowed_ips
      use_default_dns
      use_default_endpoint
      use_default_mtu
      use_default_persistent_keepalive
    )a
    |> Map.new(&{&1, Ecto.Changeset.get_field(changeset, &1)})
  end

  defp create_device(attrs, socket) do
    Devices.create_device_for_user(socket.assigns.user, attrs, socket.assigns.subject)
  end

  defp binary_to_list(binary) when is_binary(binary),
    do: binary |> String.trim() |> String.split(",")

  defp binary_to_list(list) when is_list(list),
    do: list
end
