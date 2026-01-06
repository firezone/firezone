defmodule PortalWeb.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """
  alias Portal.Sandbox

  def allow_channel_sql_sandbox(socket) do
    if Map.has_key?(socket.assigns, :user_agent) do
      Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, socket.assigns.user_agent)
    end

    socket
  end

  def allow_live_ecto_sandbox(socket) do
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)

    if Phoenix.LiveView.connected?(socket) do
      Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, user_agent)
    end

    with %{owner: test_pid} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
      Process.put(:last_caller_pid, test_pid)
    end

    socket
  end
end
