defmodule PortalAPI.Sockets.Serializer do
  @moduledoc """
  The V1 JSON serializer, but `phx_error` keeps the empty payload it had before Phoenix 1.8.17.
  Released Clients, Gateways and Relays only accept `{}` there and log a warning for anything else.
  """
  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Message, V1}

  @impl true
  defdelegate fastlane!(broadcast), to: V1.JSONSerializer

  @impl true
  def encode!(%Message{event: "phx_error"} = message) do
    V1.JSONSerializer.encode!(%{message | payload: %{}})
  end

  def encode!(message), do: V1.JSONSerializer.encode!(message)

  @impl true
  defdelegate decode!(message, opts), to: V1.JSONSerializer
end
