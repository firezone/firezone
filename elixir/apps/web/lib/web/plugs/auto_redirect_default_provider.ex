defmodule Web.Plugs.AutoRedirectDefaultProvider do
  @behaviour Plug

  use Web, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Domain.{Auth, Accounts}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %{params: %{"as" => "client", "account_id_or_slug" => account_id_or_slug}} = conn,
        _opts
      ) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_id_or_slug),
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
