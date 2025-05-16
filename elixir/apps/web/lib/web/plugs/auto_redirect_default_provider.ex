defmodule Web.Plugs.AutoRedirectDefaultProvider do
  use Phoenix.VerifiedRoutes, endpoint: Web.Endpoint, router: Web.Router
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Domain.Auth

  def init(opts), do: opts

  # client sign in
  def call(%{params: %{"as" => "client"}} = conn, _opts) do
    with account <- conn.assigns.account,
         {:ok, provider} <- Auth.fetch_default_provider_for_account(account) do
      redirect_path = ~p"/#{account}/sign_in/providers/#{provider}/redirect"

      # Append original query params
      full_redirect_path =
        if conn.query_string != "" do
          redirect_path <> "?" <> conn.query_string
        else
          redirect_path
        end

      conn
      |> redirect(to: full_redirect_path)
      |> halt()
    else
      _ -> conn
    end
  end

  # Non-client sign in
  def call(conn, _opts) do
    conn
  end
end
