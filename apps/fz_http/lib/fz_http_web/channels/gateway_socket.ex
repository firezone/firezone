defmodule FzHttpWeb.GatewaySocket do
  @moduledoc """
  Socket over which gateway authenticates and communicates with the channel
  """

  use Phoenix.Socket

  channel "gateway:*", FzHttpWeb.GatewayChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:error, reason} <-
           Guardian.Phoenix.Socket.authenticate(
             socket,
             FzHttpWeb.Auth.Gateway.Authentication,
             token
           ) do
      {:error, {:unauthorized, reason}}
    end
  end

  @impl true
  def connect(_params, _socket, _connect_info) do
    {:error, {:unauthorized, "token not present"}}
  end

  @impl true
  def connect(_socket, _connect_info) do
    {:error, {:unauthorized, "token not present"}}
  end

  @impl true
  def id(socket), do: "gateway_socket:#{Guardian.Phoenix.Socket.current_resource(socket).id}"
end
