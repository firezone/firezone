defmodule FgHttpWeb.DeviceLive.Show do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.{Devices, Rules}

  def mount(params, sess, sock), do: mount_defaults(params, sess, assign_defaults(sock, params))

  defp mount_defaults(%{"id" => id}, %{"current_user" => current_user}, socket) do
    device = Devices.get_device!(id)

    if device.user_id == current_user.id do
      {:ok, assign(socket, :device, device)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Couldn't load device.")
       |> assign(:device, nil)}
    end
  end

  def handle_event("add_rule", params, socket) do
    # XXX: Authorization
    case Rules.create_rule(params["rule"]) do
      {:ok, rule} ->
        rules = Rules.like(rule)
        {:noreply, assign(socket, rules: rules)}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
