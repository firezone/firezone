defmodule Web.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """
  alias Domain.Sandbox

  def init(opts), do: opts

  def call(conn, _opts) do
    with [user_agent] <- Plug.Conn.get_req_header(conn, "user-agent"),
         %{owner: test_pid} <-
           Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
      Process.put(:last_caller_pid, test_pid)
      conn
    else
      _ -> conn
    end
  end

  def on_mount(:default, _params, _session, socket) do
    socket = allow_live_ecto_sandbox(socket)
    {:cont, socket}
  end

  def allow_channel_sql_sandbox(socket) do
    if Map.has_key?(socket.assigns, :user_agent) do
      Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, socket.assigns.user_agent)
    end

    socket
  end

  def allow_live_ecto_sandbox(socket) do
    if Phoenix.LiveView.connected?(socket) do
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, user_agent)
    end

    socket
  end
end
