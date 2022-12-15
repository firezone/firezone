defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.AllowRules
  alias FzHttp.{Users, Notifications, Rules, Gateways, Devices}

  require Logger

  def add(subject, _user) when subject == "users" do
  end

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def add(subject, device) when subject == "devices" do
    if :ok ==
         send_event("todo", "add_peer", Devices.to_peer(device)) do
      :ok
    else
      Notifications.add(%{
        type: :error,
        message: """
        #{device.name} was created successfully but an error occurred applying its
        configuration to the WireGuard interface. Check the logs for more
        information.
        """,
        timestamp: DateTime.utc_now(),
        user: Users.get_user!(device.user_id).email
      })
    end
  end

  def add(subject, rule) when subject == "rules" do
    send_event("todo", "add_rule", AllowRules.as_setting(rule))
  end

  def delete(subject, device) when subject == "devices" do
    if :ok ==
         send_event("todo", "delete_peer", %{
           public_key: "AxVaJsPC1FSrOM5RpEXg4umTKMxkHkgMy1fl7t1xNyw="
         }) do
      :ok
    else
      Notifications.add(%{
        type: :error,
        message: """
        #{device.name} was deleted successfully but an error occurred applying its
        configuration to the WireGuard interface. Check the logs for more
        information.
        """,
        timestamp: DateTime.utc_now(),
        user: Users.get_user!(device.user_id).email
      })
    end
  end

  def delete(subject, rule) when subject == "rules" do
    send_event("todo", "delete_rule", AllowRules.as_setting(rule))
  end

  def delete(subject, _user) when subject == "users" do
    send_event_all("delete_user", %{})
  end

  def set_config do
    # XXX: Actually do something when sessions expire
  end

  defp send_event(id, event, payload) do
    FzHttpWeb.Endpoint.broadcast("gateway:" <> id, event, %{"#{event}" => payload})
  end

  defp send_event_all(event, payload) do
    send_event("all", event, payload)
  end
end
