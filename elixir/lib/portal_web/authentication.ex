defmodule PortalWeb.Authentication do
  use PortalWeb, :verified_routes

  @sign_in_params ["as", "state", "nonce", "redirect_to"]

  @analytics_params ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]

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
  def take_sign_in_params(nil), do: %{}

  def take_sign_in_params(params), do: take_non_empty(params, @sign_in_params)

  @doc """
  Returns the sign in parameters plus the campaign parameters that should survive a
  redirect into the sign in flow.
  """
  def take_sign_in_redirect_params(nil), do: %{}

  def take_sign_in_redirect_params(params),
    do: take_non_empty(params, @sign_in_params ++ @analytics_params)

  @doc """
  Returns true when the params represent a client sign-in flow.
  """
  def client_sign_in?(%{"as" => as}) when as in ["client", "gui-client", "headless-client"],
    do: true

  def client_sign_in?(_params), do: false

  defp take_non_empty(params, keys) do
    params
    |> Map.take(keys)
    |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end
end
