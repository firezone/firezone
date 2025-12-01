defmodule Web.Session.Redirector do
  @moduledoc """
  Centralized module for handling all session-related redirects.

  This module provides a single source of truth for:
  - Browser redirects (portal sign-in and out with redirect_to validation)
  - Client redirects (setting cookie and redirecting to client_redirect.html)
  - Redirect path sanitization and validation
  """
  use Web, :verified_routes

  alias Domain.Safe

  @doc """
  Sanitizes and validates a redirect_to parameter.

  Returns the redirect_to if it's valid (starts with account ID or slug),
  otherwise returns the default portal path.
  """
  def sanitize_redirect_to(%Domain.Account{} = account, redirect_to)
      when is_binary(redirect_to) do
    if String.starts_with?(redirect_to, "/#{account.id}") or
         String.starts_with?(redirect_to, "/#{account.slug}") do
      redirect_to
    else
      default_portal_path(account)
    end
  end

  def sanitize_redirect_to(%Domain.Account{} = account, _redirect_to) do
    default_portal_path(account)
  end

  @doc """
  Redirects to either a validated `redirect_to` parameter or the default portal path.

  Works with both LiveView sockets and Plug connections.
  """
  def portal_signed_in(%Phoenix.LiveView.Socket{} = socket, %Domain.Account{} = account, params) do
    redirect_to = sanitize_redirect_to(account, params["redirect_to"])
    Phoenix.LiveView.redirect(socket, to: redirect_to)
  end

  def portal_signed_in(%Plug.Conn{} = conn, %Domain.Account{} = account, params) do
    redirect_to = sanitize_redirect_to(account, params["redirect_to"])

    conn
    |> Web.Auth.prepend_recent_account_id(account.id)
    |> Phoenix.Controller.redirect(to: redirect_to)
  end

  @doc """
  Redirects to the client application after sign-in.

  Sets a cookie with client auth data and renders the client_redirect.html page
  which handles the platform-specific redirect.
  """
  def client_signed_in(%Plug.Conn{} = conn, actor_name, identifier, fragment, state) do
    client_auth_data = %{
      actor_name: actor_name,
      fragment: fragment,
      identity_provider_identifier: identifier,
      state: state
    }

    redirect_url = ~p"/#{conn.assigns.account.slug}/sign_in/client_redirect"

    conn
    |> Web.Auth.put_client_auth_data_to_cookie(client_auth_data)
    |> Web.Auth.prepend_recent_account_id(conn.assigns.account.id)
    |> Phoenix.Controller.put_root_layout(false)
    |> Phoenix.Controller.put_view(Web.SignInHTML)
    |> Phoenix.Controller.render("client_redirect.html",
      redirect_url: redirect_url,
      layout: false
    )
  end

  @doc """
  Handles browser sign-out redirects.

  For unauthenticated users, redirects to the account home page.
  """

  def signed_out(
        %Plug.Conn{assigns: %{subject: %Domain.Auth.Subject{} = subject, account: account}} =
          conn,
        account_or_slug
      ) do
    post_sign_out_url = url(~p"/#{account_or_slug}")
    # Delete the token for the subject
    import Ecto.Query
    query = from(t in Domain.Token, where: t.id == ^subject.token_id)
    {_num_deleted, _} = Safe.scoped(subject) |> Safe.delete_all(query)

    conn = delete_session(conn, account.id)

    Phoenix.Controller.redirect(conn, external: post_sign_out_url)
  end

  def signed_out(%Plug.Conn{} = conn, account_id_or_slug) do
    conn
    |> Phoenix.Controller.redirect(to: ~p"/#{account_id_or_slug}")
  end

  defp delete_session(conn, account_id) do
    conn
    |> Web.Session.Cookie.delete_account_cookie(account_id)
    |> Plug.Conn.configure_session(drop: true)
    |> Plug.Conn.clear_session()
  end

  defp default_portal_path(%Domain.Account{} = account) do
    ~p"/#{account.id}/sites"
  end
end
