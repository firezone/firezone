defmodule PortalWeb.SignInController do
  use Web, :controller

  def client_redirect(conn, _params) do
    account = conn.assigns.account

    case PortalWeb.Cookie.ClientAuth.fetch(conn) do
      %PortalWeb.Cookie.ClientAuth{} = cookie ->
        {scheme, url} =
          Portal.Config.fetch_env!(:web, :client_handler)
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
        redirect(conn, to: ~p"/#{account}/sign_in/client_auth_error")
    end
  end

  def client_auth_error(conn, _params) do
    render(conn, :client_auth_error, layout: false)
  end

  defp format_redirect_url(raw_client_handler) do
    uri = URI.parse(raw_client_handler)

    maybe_host = if uri.host == "", do: "", else: "#{uri.host}:#{uri.port}/"

    {uri.scheme, "#{maybe_host}handle_client_sign_in_callback"}
  end
end
