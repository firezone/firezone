defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{
    Notifications,
    AllowRules,
    Devices,
    Devices.Device,
    AllowRules.AllowRule
  }

  require Logger

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def add(%Device{} = device) do
    if :ok ==
         send_event("add_peer", Devices.to_peer(device)) do
      :ok
    else
      Notifications.add_error(:device, :added, device)
    end
  end

  def add(%AllowRule{} = rule) do
    send_event("add_rule", AllowRules.as_setting(rule))
  end

  def delete(%Device{} = device) do
    if :ok ==
         send_event("delete_peer", %{
           public_key: device.public_key
         }) do
      :ok
    else
      Notifications.add_error(:device, :deleted, device)
    end
  end

  def delete(%AllowRule{} = rule) do
    send_event("delete_rule", AllowRules.as_setting(rule))
  end

  def set_config do
    # XXX: Actually do something when sessions expire
  end

  defp send_event(event, payload) do
    FzHttpWeb.Endpoint.broadcast("gateway", event, %{"#{event}" => payload})
  end
end
