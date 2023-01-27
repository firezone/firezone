defmodule FzHttpWeb.GatewaySocket do
  @moduledoc """
  Socket over which gateway authenticates and communicates with the channel
  """
  alias FzHttp.Gateways

  use Phoenix.Socket

  channel("gateway", FzHttpWeb.GatewayChannel)

  @impl true
  def connect(%{"secret" => secret}, socket, _connect_info) do
    if authorized?(secret) do
      case Gateways.find_or_create_default_gateway() do
        {:ok, gateway} ->
          {:ok, assign(socket, :gateway, gateway)}

        {:error, err} ->
          {:error, {:gateway, err}}
      end
    else
      {:error, {:unauthorized, "invalid token"}}
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
  def id(socket), do: "gateway_socket:#{socket.assigns.gateway.id}"

  defp authorized?(secret) do
    case Base.decode64(secret) do
      {:ok, secret} -> check_secret(secret)
      :error -> false
    end
  end

  defp check_secret(secret) do
    :crypto.hash_equals(
      secret,
      Base.decode64!(FzHttp.Config.fetch_env!(:fz_http, :gateway_registration_token))
    )
  end
end
