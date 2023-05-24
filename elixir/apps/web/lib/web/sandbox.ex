defmodule Web.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """
  alias Domain.Sandbox

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
