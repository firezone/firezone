defmodule PortalWeb.Authentication do
  use PortalWeb, :verified_routes
  require Logger

  @doc """
  Returns the real IP address of the client.
  """
  def real_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)

    real_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, PortalWeb.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end

  @doc """
  Returns non-empty parameters that should be persisted during sign in flow.
  """
  def take_sign_in_params(params) do
    params
    |> Map.take(["as", "state", "nonce", "redirect_to"])
    |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end
end
