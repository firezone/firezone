defmodule PortalWeb.OAuthController do
  @moduledoc """
  The entry point to the authorization endpoint, plus token and revocation.

  Consent itself is `PortalWeb.OAuthConsent`, which runs behind the portal's
  normal sign-in, so the person granting access authenticates exactly as they
  always do, through whichever identity provider their account uses. The MCP
  client never sees those credentials.
  """

  use PortalWeb, :controller

  alias Portal.OAuth
  alias __MODULE__.Database

  @authorize_params ~w[client_id redirect_uri response_type scope resource code_challenge
                       code_challenge_method state]

  @doc """
  Entry point named by the authorization server metadata.

  Portal sign-in is per account, but a client reaching this URL has no idea
  which account its user belongs to. Someone with exactly one recent account
  goes straight through; anyone else picks one first.
  """
  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, params) do
    # Resolved before sign-in on purpose. A bad client or redirect URI is the
    # caller's mistake, so saying so now beats making someone authenticate
    # first. It also caches the client's metadata, which is what lets sign-in
    # name the app it is being asked to connect.
    case OAuth.validate_client(params) do
      {:ok, client, _redirect_uri} -> choose_account(conn, params, client)
      {:error, error, description} -> render_error(conn, error, description)
    end
  end

  @spec token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    params |> OAuth.exchange(OAuth.resource_uri()) |> send_token(conn)
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    params |> OAuth.refresh(OAuth.resource_uri()) |> send_token(conn)
  end

  def token(conn, _params) do
    send_oauth_error(
      conn,
      400,
      "unsupported_grant_type",
      "Only authorization_code and refresh_token are supported."
    )
  end

  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, params) do
    :ok = OAuth.revoke(params["token"] || "")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, "")
  end

  defp choose_account(conn, %{"account_id_or_slug" => slug} = params, client) when slug != "" do
    # Typed into the chooser. Checked here rather than redirected blindly: an
    # account that does not exist would otherwise surface as a crash on a
    # sign-in page the person never asked for.
    case Database.fetch_account_by_id_or_slug(slug) do
      %Portal.Account{} = account ->
        redirect(conn, to: ~p"/#{account}/oauth/authorize?#{Map.take(params, @authorize_params)}")

      nil ->
        render_chooser(conn, params, client, "No account found for \"#{slug}\".")
    end
  end

  defp choose_account(conn, params, client) do
    query = Map.take(params, @authorize_params)

    %PortalWeb.Cookie.RecentAccounts{account_ids: account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    case Database.get_accounts_by_ids(account_ids) do
      [account] -> redirect(conn, to: ~p"/#{account}/oauth/authorize?#{query}")
      accounts -> render_chooser(conn, params, client, nil, accounts)
    end
  end

  defp render_chooser(conn, params, client, error, accounts \\ []) do
    conn
    |> standalone_layout()
    |> render("choose_account.html",
      accounts: accounts,
      query: Map.take(params, @authorize_params),
      client: client,
      error: error
    )
  end

  defp standalone_layout(conn) do
    put_layout(conn, html: {PortalWeb.Layouts, :standalone})
  end

  defp send_token({:ok, response}, conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(response)
  end

  defp send_token({:error, error, description}, conn) do
    send_oauth_error(conn, 400, error, description)
  end

  defp send_oauth_error(conn, status, error, description) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: error, error_description: description})
  end

  defp render_error(conn, error, description) do
    conn
    |> standalone_layout()
    |> put_status(400)
    |> render("error.html", error: error, description: description)
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Safe

    def fetch_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Portal.Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Portal.Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end

    def get_accounts_by_ids(account_ids) do
      from(accounts in Portal.Account, where: accounts.id in ^account_ids)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
