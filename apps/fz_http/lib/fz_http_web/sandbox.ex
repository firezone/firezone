defmodule FzHttpWeb.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels and LiveView) to access SQL sandbox in test environment.
  """
  alias Phoenix.Ecto.SQL.Sandbox

  if Mix.env() in [:test, :dev] do
    def allow_channel_sql_sandbox(socket) do
      if Map.has_key?(socket.assigns, :user_agent) do
        user_agent = socket.assigns.user_agent
        Sandbox.allow(user_agent, Ecto.Adapters.SQL.Sandbox)
      else
        :ok
      end
    end

    def allow_live_ecto_sandbox(socket) do
      %{assigns: %{user_agent: user_agent}} =
        socket =
        Phoenix.Component.assign_new(socket, :user_agent, fn ->
          Phoenix.LiveView.get_connect_info(socket, :user_agent)
        end)

      if Phoenix.LiveView.connected?(socket),
        do: Sandbox.allow(user_agent, Ecto.Adapters.SQL.Sandbox),
        else: :ok

      socket
    end
  else
    def allow_channel_sql_sandbox(_socket), do: :ok
    def allow_live_ecto_sandbox(socket), do: socket
  end
end
