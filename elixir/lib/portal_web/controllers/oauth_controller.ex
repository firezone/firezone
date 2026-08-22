defmodule PortalWeb.OAuthController do
  @moduledoc """
  The authorization, token, and revocation endpoints.

  `authorize/2` runs behind the portal's normal sign-in, so the person granting
  access authenticates exactly as they always do, through whichever identity
  provider their account uses. The MCP client never sees those credentials.

  Errors are delivered two different ways on purpose. Until the client and its
  redirect URI have been checked, nothing may be sent to that URI, because doing
  so would make this endpoint a redirector for any URL an attacker chose. Those
  failures render a page instead.
  """

  use PortalWeb, :controller

  alias Portal.OAuth
  alias PortalAPI.MCP
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
    query = params |> Map.take(@authorize_params) |> URI.encode_query()

    %PortalWeb.Cookie.RecentAccounts{account_ids: account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    case Database.get_accounts_by_ids(account_ids) do
      [account] ->
        redirect(conn, to: ~p"/#{account}/oauth/authorize?#{query}")

      accounts ->
        conn
        |> put_layout(html: {PortalWeb.Layouts, :auth})
        |> render("choose_account.html", accounts: accounts, query: query)
    end
  end

  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, params) do
    case OAuth.validate_client(params) do
      {:ok, client, redirect_uri} ->
        continue_authorize(conn, params, client, redirect_uri)

      {:error, error, description} ->
        render_error(conn, error, description)
    end
  end

  @spec consent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def consent(conn, params) do
    case OAuth.validate_client(params) do
      {:ok, client, redirect_uri} ->
        decide(conn, params, client, redirect_uri)

      {:error, error, description} ->
        render_error(conn, error, description)
    end
  end

  @spec token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    params |> OAuth.exchange(MCP.resource_uri()) |> send_token(conn)
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    params |> OAuth.refresh(MCP.resource_uri()) |> send_token(conn)
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

  defp continue_authorize(conn, params, client, redirect_uri) do
    case OAuth.validate_request(params, client, redirect_uri, MCP.resource_uri()) do
      {:ok, request} ->
        conn
        |> put_layout(html: {PortalWeb.Layouts, :auth})
        |> render("consent.html",
          request: request,
          account: conn.assigns.account,
          subject: conn.assigns.subject
        )

      {:error, error, description} ->
        redirect_with_error(conn, redirect_uri, params["state"], error, description)
    end
  end

  # The form is re-validated rather than trusted. Everything it posts back came
  # from the browser, so treating it as already checked would let a tampered
  # form widen the scopes that were displayed.
  defp decide(conn, %{"decision" => "allow"} = params, client, redirect_uri) do
    with {:ok, request} <-
           OAuth.validate_request(params, client, redirect_uri, MCP.resource_uri()),
         {:ok, code} <- OAuth.consent(request, conn.assigns.subject) do
      redirect_to_client(conn, redirect_uri, %{"code" => code, "state" => params["state"]})
    else
      {:error, error, description} ->
        redirect_with_error(conn, redirect_uri, params["state"], error, description)

      {:error, _changeset} ->
        redirect_with_error(
          conn,
          redirect_uri,
          params["state"],
          "server_error",
          "The authorization could not be recorded."
        )
    end
  end

  defp decide(conn, params, _client, redirect_uri) do
    redirect_with_error(
      conn,
      redirect_uri,
      params["state"],
      "access_denied",
      "The request was declined."
    )
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
    |> put_layout(html: {PortalWeb.Layouts, :auth})
    |> put_status(400)
    |> render("error.html", error: error, description: description)
  end

  defp redirect_with_error(conn, redirect_uri, state, error, description) do
    redirect_to_client(conn, redirect_uri, %{
      "error" => error,
      "error_description" => description,
      "state" => state
    })
  end

  # `iss` lets a client that talks to several authorization servers detect a
  # response that came back from the wrong one.
  defp redirect_to_client(conn, redirect_uri, params) do
    uri = URI.parse(redirect_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(params)
      |> Map.put("iss", PortalWeb.Endpoint.url())
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    redirect(conn, external: URI.to_string(%{uri | query: query}))
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Safe

    def get_accounts_by_ids(account_ids) do
      from(accounts in Portal.Account, where: accounts.id in ^account_ids)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
