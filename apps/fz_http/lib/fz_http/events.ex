defmodule FzHttp.Events do
  @moduledoc """
  Handles interfacing with other processes in the system.
  """

  alias FzHttp.{Devices, Rules, Users, Notifications}

  require Logger

  def add(subject, user) when subject == "users" do
  end

  # set_config is used because devices need to be re-evaluated in case a
  # device is added to a User that's not active.
  def add(subject, device) when subject == "devices" do
    with :ok <-
           send_event("todo", "add_peer", %{
             public_key: "AxVaJsPC1FSrOM5RpEXg4umTKMxkHkgMy1fl7t1xNyw=",
             preshared_key: "LZBIpoLNCkIe56cPM+5pY/hP2pu7SGARvQZEThmuPYM=",
             user_uuid: "3118158c-29cb-47d6-adbf-5edd15f1af17",
             allowed_ips: [
               "100.64.11.22/32"
             ]
           }) do
      :ok
    else
      _err ->
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
    send_event("todo", "add_rule", %{
      dst: "0.0.0.0/8",
      port_range: %{
        range_start: 80,
        range_end: 81,
        protocol: "tcp"
      },
      user_uuid: "3118158c-29cb-47d6-adbf-5edd15f1af17"
    })
  end

  def delete(subject, device) when subject == "devices" do
    with :ok <-
           send_event("todo", "delete_peer", %{
             public_key: "AxVaJsPC1FSrOM5RpEXg4umTKMxkHkgMy1fl7t1xNyw="
           }) do
      :ok
    else
      _err ->
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
    send_event("todo", "delete_rule", %{
      dst: "0.0.0.0/8",
      port_range: %{
        range_start: 80,
        range_end: 81,
        protocol: "tcp"
      },
      user_uuid: "3118158c-29cb-47d6-adbf-5edd15f1af17"
    })
  end

  def delete(subject, user) when subject == "users" do
    send_event_all("delete_user", %{})
  end

  defp send_event(id, event, payload) do
    FzHttpWeb.Endpoint.broadcast("gateway:" <> id, event, %{"#{event}" => payload})
  end

  defp send_event_all(event, payload) do
    send_event("all", event, payload)
  end
end
