defmodule FzHttpWeb.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """

  def allow_channel_sql_sandbox(socket) do
    if Map.has_key?(socket.assigns, :user_agent) do
      allow(socket.assigns.user_agent)
    end

    socket
  end

  def allow_live_ecto_sandbox(socket) do
    if Phoenix.LiveView.connected?(socket) do
      socket
      |> Phoenix.LiveView.get_connect_info(:user_agent)
      |> allow()
    end

    socket
  end

  if Mix.env() in [:test, :dev] do
    defp allow(metadata) do
      # We notify the test process that there is someone trying to access the sandbox,
      # so that it can optionally await after test has passed for the sandbox to be
      # closed gracefully
      %{owner: owner_pid} = Phoenix.Ecto.SQL.Sandbox.decode_metadata(metadata)
      send(owner_pid, {:sandbox_access, self()})

      Phoenix.Ecto.SQL.Sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)
    end
  else
    defp allow(_metadata) do
      :ok
    end
  end
end
