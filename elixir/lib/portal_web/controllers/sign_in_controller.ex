defmodule PortalWeb.SignInController do
  use PortalWeb, :controller

  @default_client_auth_error "Please close this window and start the sign in process again."

  def client_redirect(conn, _params) do
    account = conn.assigns.account

    case PortalWeb.Cookie.ClientAuth.fetch(conn) do
      %PortalWeb.Cookie.ClientAuth{} = cookie ->
        {scheme, url} =
          Portal.Config.fetch_env!(:portal, :client_handler)
          |> format_redirect_url()

        query =
          %{
            actor_name: cookie.actor_name,
            fragment: cookie.fragment,
            identity_provider_identifier: cookie.identity_provider_identifier,
            state: cookie.state,
            account_slug: account.slug,
            account_name: account.name
          }
          |> URI.encode_query()

        redirect(conn, external: "#{scheme}://#{url}?#{query}")

      nil ->
        redirect(conn, to: client_auth_error_path(account, %{}, @default_client_auth_error))
    end
  end

  def client_auth_error(conn, params) do
    account = conn.assigns.account
    retry_params = PortalWeb.Authentication.take_sign_in_params(params)

    error =
      params["error"] ||
        Phoenix.Flash.get(conn.assigns[:flash] || %{}, :error) ||
        @default_client_auth_error

    render(conn, :client_auth_error,
      layout: false,
      error: error,
      retry_path: retry_path(account, retry_params)
    )
  end

  def client_account_disabled(conn, _params) do
    render(conn, :client_account_disabled, layout: false)
  end

  defp format_redirect_url(raw_client_handler) do
    uri = URI.parse(raw_client_handler)

    maybe_host = if uri.host == "", do: "", else: "#{uri.host}:#{uri.port}/"

    {uri.scheme, "#{maybe_host}handle_client_sign_in_callback"}
  end

  defp client_auth_error_path(account, params, error) do
    query =
      params
      |> PortalWeb.Authentication.take_sign_in_params()
      |> Map.put("error", error)

    ~p"/#{account}/sign_in/client_auth_error?#{query}"
  end

  defp retry_path(account, params) when map_size(params) == 0, do: ~p"/#{account}/sign_in"
  defp retry_path(account, params), do: ~p"/#{account}/sign_in?#{params}"
end
