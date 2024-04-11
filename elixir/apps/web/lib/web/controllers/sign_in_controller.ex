defmodule Web.SignInController do
  use Web, :controller

  def deeplink(conn, _params) do
    {scheme, url} =
      Domain.Config.fetch_env!(:web, :client_handler)
      |> format_redirect_url()

    account = conn.assigns.account

    query =
      conn.assigns.client_auth_data
      |> Keyword.put_new(:account_slug, account.slug)
      |> Keyword.put_new(:account_name, account.name)
      |> URI.encode_query()

    redirect(conn, external: "#{scheme}://#{url}?#{query}")
  end

  defp format_redirect_url(raw_client_handler) do
    uri = URI.parse(raw_client_handler)

    maybe_host = if uri.host == "", do: "", else: "#{uri.host}:#{uri.port}/"

    {uri.scheme, "#{maybe_host}handle_client_sign_in_callback"}
  end
end
