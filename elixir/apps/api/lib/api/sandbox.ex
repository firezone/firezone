defmodule API.Sandbox do
  @moduledoc """
  A set of helpers that allow Phoenix components (Channels) to access SQL sandbox in test environment.
  """
  alias Domain.Sandbox

  def allow_sql_sandbox(socket) do
    if Map.has_key?(socket.assigns, :user_agent) do
      Sandbox.allow(Phoenix.Ecto.SQL.Sandbox, socket.assigns.user_agent)
    end

    socket
  end
end
