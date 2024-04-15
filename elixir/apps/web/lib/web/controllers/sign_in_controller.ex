defmodule Web.SignInController do
  use Web, :controller

  def client_redirect(conn, _params) do
    account = conn.assigns.account

    with {:ok, client_auth_data, conn} <- Web.Auth.get_client_auth_data_from_cookie(conn) do
      {scheme, url} =
        Domain.Config.fetch_env!(:web, :client_handler)
        |> format_redirect_url()

      query =
        client_auth_data
        |> Keyword.put_new(:account_slug, account.slug)
        |> Keyword.put_new(:account_name, account.name)
        |> URI.encode_query()

      redirect(conn, external: "#{scheme}://#{url}?#{query}")
    else
      {:error, conn} ->
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
