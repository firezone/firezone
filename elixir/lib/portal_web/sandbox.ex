defmodule PortalWeb.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """

  # The metadata is decoded with an unsafe binary_to_term on the User-Agent, so
  # it must never run outside the SQL sandbox.
  if Application.compile_env(:portal, :sql_sandbox) do
    def allow_live_ecto_sandbox(socket) do
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)

      if Phoenix.LiveView.connected?(socket) do
        Portal.Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, user_agent)
      end

      with %{owner: test_pid} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
        Process.put(:last_caller_pid, test_pid)
      end

      socket
    end
  else
    def allow_live_ecto_sandbox(socket), do: socket
  end
end
