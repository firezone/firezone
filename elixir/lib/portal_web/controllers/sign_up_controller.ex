defmodule PortalWeb.SignUpController do
  use PortalWeb, :controller
  alias PortalWeb.Session.Redirector
  alias PortalWeb.SignUp
  require Logger

  @verified_providers ~w[google github email]

  @doc """
  Opens the link from an email sign-up and stores the verified email in the session, so the
  details form at `/sign_up/email` can finish the sign-up.

  Nothing is created here, so link scanners that open the link change nothing. The link
  only works from the browser that requested it, see `PortalWeb.Cookie.SignUpBrowser`.
  """
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"token" => token}) when is_binary(token) do
    browser_id = PortalWeb.Cookie.SignUpBrowser.fetch(conn)

    case SignUp.verify_sign_up_token(token, browser_id) do
      {:ok, %{email: email} = claims} when is_binary(email) ->
        identity = SignUp.email_session_identity(email, Map.get(claims, :website_attribution))

        conn
        |> put_session(SignUp.session_key(), identity)
        |> redirect(to: ~p"/sign_up/email")

      {:error, :different_browser} ->
        redirect(conn, to: ~p"/sign_up/different_browser")

      {:error, message} when is_binary(message) ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/sign_up")
    end
  end

  def verify(conn, _params), do: redirect(conn, to: ~p"/sign_up")

  @doc """
  Completes a sign-up from the details form and signs the new admin in.

  The email comes only from the identity verified by Google, GitHub or an email link and
  stored in the session, never from the submitted form. Email sign-ups are checked by
  `PortalWeb.SignUpReview` first and may be held for an approver.

  The identity is removed from the session once the account exists or the sign-up is held.
  A replayed copy of an older session cookie still carries it, but by then the email owns
  an account or has a review pending, so nothing new is created and nobody is signed in.
  """
  @spec complete_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete_identity(conn, %{"provider" => provider, "registration" => attrs})
      when provider in @verified_providers and is_map(attrs) do
    case SignUp.identity_from_session(get_session(conn)) do
      %{provider: ^provider} = identity -> complete(conn, identity, attrs)
      # A missing or expired identity is shown by the sign-up page.
      _other -> redirect(conn, to: ~p"/sign_up/#{provider}")
    end
  end

  def complete_identity(conn, _params), do: redirect(conn, to: ~p"/sign_up")

  defp complete(conn, %{provider: "email"} = identity, attrs) do
    case SignUp.complete_verified_email_sign_up(
           identity,
           attrs,
           conn.assigns[:user_agent],
           conn.remote_ip
         ) do
      {:ok, result} ->
        conn
        |> delete_session(SignUp.session_key())
        |> sign_in(result.account, result.provider, result.actor)

      :pending_review ->
        conn
        |> delete_session(SignUp.session_key())
        |> redirect(to: ~p"/sign_up/pending")

      error ->
        completion_error(conn, "email", error)
    end
  end

  defp complete(conn, identity, attrs) do
    case SignUp.complete_identity_sign_up(
           identity,
           attrs,
           PortalWeb.WebsiteAttribution.fetch(get_session(conn)),
           conn.assigns[:user_agent],
           conn.remote_ip
         ) do
      {:ok, result} ->
        conn
        |> delete_session(SignUp.session_key())
        |> sign_in(result.account, result.idp_provider, result.actor)

      error ->
        completion_error(conn, identity.provider, error)
    end
  end

  defp completion_error(conn, provider, {:error, %Ecto.Changeset{}}) do
    conn
    |> put_flash(:error, "Please check your details and try again.")
    |> redirect(to: ~p"/sign_up/#{provider}")
  end

  defp completion_error(conn, provider, {:error, message}) when is_binary(message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign_up/#{provider}")
  end

  # Existing accounts are listed by the sign-up page.
  defp completion_error(conn, provider, {:error, {:account_exists, _accounts}}) do
    redirect(conn, to: ~p"/sign_up/#{provider}")
  end

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
