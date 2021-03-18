defmodule FgHttpWeb.DeviceLive.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.{Devices, Rules}

  def mount(params, sess, sock), do: mount_defaults(params, sess, assign_defaults(sock, params))

  defp mount_defaults(_params, %{"current_user" => current_user}, socket) do
    {:ok, assign(socket, :devices, Devices.list_devices(current_user, :with_roles))}
  end

  def handle_event("create_device", params, socket) do
    # XXX: Remove device from WireGuard if create isn't successful
    {:ok, privkey, pubkey, server_pubkey, psk} = @events_module.create_device()

    device_attrs = %{
      private_key: privkey,
      public_key: pubkey,
      server_public_key: server_pubkey,
      preshared_key: psk
    }

    attributes =
      Map.merge(
        %{
          user_id: socket.assigns.current_user.id,
          name: Devices.rand_name()
        },
        device_attrs
      )

    case Devices.create_device(attributes) do
      {:ok, device} ->
        {:noreply,
         socket
         |> put_flash(:info, "Device added successfully.")
         |> redirect(to: Routes.device_path(socket, :show, "5"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error creating device.")}
    end
  end
end
