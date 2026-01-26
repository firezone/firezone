defmodule PortalWeb.Session.Redirector do
  @moduledoc """
  Centralized module for handling all session-related redirects.

  This module provides a single source of truth for:
  - Browser redirects (portal sign-in and out with redirect_to validation)
  - Client redirects (setting cookie and redirecting to client_redirect.html)
  - Redirect path sanitization and validation
  """
  use PortalWeb, :verified_routes

  alias Portal.Auth
  alias Portal.ClientToken

  @doc """
  Sanitizes and validates a redirect_to parameter.

  Returns the redirect_to if it's valid (starts with account ID or slug),
  otherwise returns the default portal path.
  """
  def sanitize_redirect_to(%Portal.Account{} = account, redirect_to)
      when is_binary(redirect_to) do
    if String.starts_with?(redirect_to, "/#{account.id}") or
         String.starts_with?(redirect_to, "/#{account.slug}") do
      redirect_to
    else
      default_portal_path(account)
    end
  end

  def sanitize_redirect_to(%Portal.Account{} = account, _redirect_to) do
    default_portal_path(account)
  end

  @doc """
  Redirects to either a validated `redirect_to` parameter or the default portal path.

  Works with both LiveView sockets and Plug connections.
  """
  def portal_signed_in(%Phoenix.LiveView.Socket{} = socket, %Portal.Account{} = account, params) do
    redirect_to = sanitize_redirect_to(account, params["redirect_to"])
    Phoenix.LiveView.redirect(socket, to: redirect_to)
  end

  def portal_signed_in(%Plug.Conn{} = conn, %Portal.Account{} = account, params) do
    redirect_to = sanitize_redirect_to(account, params["redirect_to"])

    conn
    |> PortalWeb.Cookie.RecentAccounts.prepend(account.id)
    |> Phoenix.Controller.redirect(to: redirect_to)
  end

  @doc """
  Redirects to the GUI client application after sign-in.

  Sets a cookie with client auth data and renders the client_redirect.html page
  which handles the platform-specific redirect.
  """
  def gui_client_signed_in(
        %Plug.Conn{} = conn,
        account,
        actor_name,
        identifier,
        %ClientToken{} = token,
        state
      ) do
    fragment = Portal.Auth.encode_fragment!(token)

    client_auth_cookie = %PortalWeb.Cookie.ClientAuth{
      actor_name: actor_name,
      fragment: fragment,
      identity_provider_identifier: identifier,
      state: state
    }

    redirect_url = ~p"/#{account.slug}/sign_in/client_redirect"

    conn
    |> PortalWeb.Cookie.ClientAuth.put(client_auth_cookie)
    |> PortalWeb.Cookie.RecentAccounts.prepend(account.id)
    |> Phoenix.Controller.put_root_layout(false)
    |> Phoenix.Controller.put_view(PortalWeb.SignInHTML)
    |> Phoenix.Controller.render("client_redirect.html",
      redirect_url: redirect_url,
      account: account,
      layout: false
    )
  end

  @doc """
  Alias for gui_client_signed_in for backward compatibility.
  """
  def client_signed_in(conn, account, actor_name, identifier, token, state) do
    gui_client_signed_in(conn, account, actor_name, identifier, token, state)
  end

  @doc """
  Shows the token to the headless client user.

  Renders a page displaying the token with a copy button for the user to
  manually copy and paste into their headless client.
  """
  def headless_client_signed_in(
        %Plug.Conn{} = conn,
        account,
        actor_name,
        %ClientToken{} = token,
        state
      ) do
    fragment = Portal.Auth.encode_fragment!(token)

    conn
    |> PortalWeb.Cookie.RecentAccounts.prepend(account.id)
    |> Phoenix.Controller.put_root_layout(false)
    |> Phoenix.Controller.put_view(PortalWeb.SignInHTML)
    |> Phoenix.Controller.render("headless_client_token.html",
      token: fragment,
      actor_name: actor_name,
      account: account,
      expires_at: token.expires_at,
      state: state,
      layout: false
    )
  end

  @doc """
  Handles browser sign-out redirects.

  For unauthenticated users, redirects to the account home page.
  """

  def signed_out(
        %Plug.Conn{assigns: %{subject: %Auth.Subject{} = subject, account: account}} =
          conn,
        account_or_slug
      ) do
    post_sign_out_url = url(~p"/#{account_or_slug}")

    # Delete the portal session for the subject
    %{type: :portal_session, id: portal_session_id} = subject.credential

    :ok =
      Auth.delete_portal_session(%Portal.PortalSession{
        account_id: account.id,
        id: portal_session_id
      })

    conn = delete_session(conn, account.id)

    Phoenix.Controller.redirect(conn, external: post_sign_out_url)
  end

  def signed_out(%Plug.Conn{} = conn, account_id_or_slug) do
    conn
    |> Phoenix.Controller.redirect(to: ~p"/#{account_id_or_slug}")
  end

  defp delete_session(conn, account_id) do
    conn
    |> PortalWeb.Cookie.Session.delete(account_id)
    |> Plug.Conn.configure_session(drop: true)
    |> Plug.Conn.clear_session()
  end

  defp default_portal_path(%Portal.Account{} = account) do
    ~p"/#{account}/sites"
  end
end
