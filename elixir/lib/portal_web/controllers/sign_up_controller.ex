defmodule PortalWeb.SignUpController do
  use PortalWeb, :controller
  alias PortalWeb.Session.Redirector
  require Logger

  @identity_providers ~w[google github]

  @doc """
  Completes an email sign-up from its verification link and signs the new admin in.

  Only the request that creates the account gets a session. Once the account exists,
  the link sends the user to the regular sign-in form, so replaying it grants nothing.
  The link only works from the browser that requested it, see `PortalWeb.Cookie.SignUpBrowser`.
  """
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"token" => token}) when is_binary(token) do
    browser_id = PortalWeb.Cookie.SignUpBrowser.fetch(conn)

    with {:ok, registration_claims} <- PortalWeb.SignUp.verify_sign_up_token(token, browser_id),
         {:ok, result} <-
           PortalWeb.SignUp.complete_email_sign_up(
             registration_claims,
             conn.assigns[:user_agent],
             conn.remote_ip
           ) do
      sign_in(conn, result.account, result.provider, result.actor)
    else
      {:error, {:account_exists, accounts}} ->
        redirect(conn, to: ~p"/#{List.last(accounts)}/sign_in")

      # The verify page explains which browser to use.
      {:error, :different_browser} ->
        redirect(conn, to: ~p"/verify_sign_up?token=#{token}")

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/verify_sign_up?token=#{token}")
    end
  end

  def verify(conn, _params), do: redirect(conn, to: ~p"/sign_up")

  @doc """
  Completes a Google or GitHub sign-up and signs the new admin in with that provider.

  The email comes only from the identity `PortalWeb.OIDCController` verified and stored in the
  session, never from the submitted form. The identity is removed from the session once the
  account exists. A replayed copy of an older session cookie still carries it, but by then the
  email owns an account, so the request is turned away without signing anyone in.
  """
  @spec complete_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete_identity(conn, %{"provider" => provider, "registration" => attrs})
      when provider in @identity_providers and is_map(attrs) do
    session = get_session(conn)

    with %{provider: ^provider} = identity <- PortalWeb.SignUp.identity_from_session(session),
         {:ok, result} <-
           PortalWeb.SignUp.complete_identity_sign_up(
             identity,
             attrs,
             PortalWeb.WebsiteAttribution.fetch(session),
             conn.assigns[:user_agent],
             conn.remote_ip
           ) do
      conn
      |> delete_session(PortalWeb.SignUp.session_key())
      |> sign_in(result.account, result.idp_provider, result.actor)
    else
      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Please check your details and try again.")
        |> redirect(to: ~p"/sign_up/#{provider}")

      {:error, message} when is_binary(message) ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/sign_up/#{provider}")

      # A missing or expired identity, or existing accounts, are shown by the sign-up page.
      _other ->
        redirect(conn, to: ~p"/sign_up/#{provider}")
    end
  end

  def complete_identity(conn, _params), do: redirect(conn, to: ~p"/sign_up")

  defp sign_in(conn, account, provider, actor) do
    context =
      Portal.Authentication.Context.build(
        conn.remote_ip,
        conn.assigns[:user_agent],
        conn.req_headers,
        :portal
      )

    lifetime_secs =
      provider.portal_session_lifetime_secs ||
        provider.__struct__.default_portal_session_lifetime_secs()

    expires_at = DateTime.add(DateTime.utc_now(), lifetime_secs, :second)

    case Portal.Authentication.create_portal_session(actor, provider.id, context, expires_at) do
      {:ok, session} ->
        conn
        |> PortalWeb.Cookie.Session.put(account.id, %PortalWeb.Cookie.Session{session_id: session.id})
        |> PortalWeb.Cookie.LastUsedProvider.put(provider.id)
        |> Redirector.portal_signed_in(account, %{}, actor)

      {:error, reason} ->
        # The account exists, so the regular sign-in form still works.
        Logger.error("Failed to sign in after sign up",
          account_id: account.id,
          reason: inspect(reason)
        )

        redirect(conn, to: ~p"/#{account}/sign_in")
    end
  end
end
