defmodule FgHttpWeb.DeviceLive.Show do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.{Devices, Rules}

  def mount(params, session, socket) do
    {:ok, assign_defaults(params, session, socket, &load_data/2)}
  end

  # XXX: LiveComponent
  def handle_event("add_whitelist_rule", params, socket) do
    # XXX: Authorization
    case Rules.create_rule(params["rule"]) do
      {:ok, rule} ->
        {:noreply, assign(socket, whitelist: Rules.like(rule))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  # XXX: LiveComponent
  def handle_event("add_blacklist_rule", params, socket) do
    # XXX: Authorization
    case Rules.create_rule(params["rule"]) do
      {:ok, rule} ->
        {:noreply, assign(socket, blacklist: Rules.like(rule))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def handle_event("delete_whitelist_rule", %{"rule_id" => rule_id}, socket) do
    # XXX: Authorization
    rule = Rules.get_rule!(rule_id)

    case Rules.delete_rule(rule) do
      {:ok, _rule} ->
        {:noreply, assign(socket, whitelist: Rules.like(rule))}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
    end
  end

  def handle_event("delete_blacklist_rule", %{"rule_id" => rule_id}, socket) do
    # XXX: Authorization
    rule = Rules.get_rule!(rule_id)

    case Rules.delete_rule(rule) do
      {:ok, _rule} ->
        {:noreply, assign(socket, blacklist: Rules.like(rule))}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
    end
  end

  def handle_event("delete_device", %{"device_id" => device_id}, socket) do
    # XXX: Authorization
    device = Devices.get_device!(device_id)

    case Devices.delete_device(device) do
      {:ok, _deleted_device} ->
        {:ok, _deleted_pubkey} = @events_module.delete_device(device.public_key)

        {:noreply,
         socket
         |> put_flash(:info, "Device deleted successfully.")
         |> redirect(to: Routes.device_index_path(socket, :index))}

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error deleting device: #{msg}")}
    end
  end

  defp load_data(%{"id" => id}, socket) do
    device = Devices.get_device!(id)

    if device.user_id == socket.assigns.current_user.id do
      rule_changeset = Rules.new_rule(%{"device_id" => id})

      assign(socket,
        device: device,
        rule_changeset: rule_changeset,
        whitelist: Rules.whitelist(device),
        blacklist: Rules.blacklist(device)
      )
    else
      not_authorized(socket)
    end
  end
end
