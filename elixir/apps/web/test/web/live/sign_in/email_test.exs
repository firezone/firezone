defmodule Web.SignIn.EmailTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)
    actor = Fixtures.Actors.create_actor(account: account, type: :account_user)

    {:ok, identity} =
      Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
      |> Domain.Auth.Adapters.Email.request_sign_in_token()

    %{
      account: account,
      provider: provider,
      actor: actor,
      identity: identity
    }
  end

  test "renders delivery confirmation page for browser users", %{
    account: account,
    provider: provider,
    conn: conn
  } do
    {:ok, lv, html} =
      live(conn, ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo")

    assert html =~ "Please check your email"
    assert has_element?(lv, ~s|a[href="https://mail.google.com/mail/"]|, "Open Gmail")
    assert has_element?(lv, ~s|a[href="https://outlook.live.com/mail/"]|, "Open Outlook")
  end

  test "renders token form for Apple users", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo&client_platform=apple"
      )

    assert has_element?(lv, ~s|form#verify-sign-in-token|)
    assert has_element?(lv, "button", "Submit")

    <<secret::binary-size(5), nonce::binary>> = identity.provider_virtual_state.sign_in_token

    conn =
      conn
      |> put_session(:sign_in_nonce, nonce)
      |> put_session(:client_platform, "apple")
      |> put_session(:client_csrf_token, "foo")

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        secret: secret
      })
      |> submit_form(conn)

    assert redirected_to(conn, 302) =~ "firezone://handle_client_sign_in_callback"
    refute conn.assigns.flash["error"]
  end

  test "renders token form for Android users", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo&client_platform=android"
      )

    <<secret::binary-size(5), nonce::binary>> = identity.provider_virtual_state.sign_in_token

    conn =
      conn
      |> put_session(:sign_in_nonce, nonce)
      |> put_session(:client_platform, "android")
      |> put_session(:client_csrf_token, "foo")

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        secret: secret
      })
      |> submit_form(conn)

    assert "/handle_client_sign_in_callback" <> _ = redirected_to(conn, 302)
    refute conn.assigns.flash["error"]
  end

  test "renders error on invalid token", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo&client_platform=android"
      )

    <<_secret::binary-size(5), nonce::binary>> = identity.provider_virtual_state.sign_in_token

    conn =
      conn
      |> put_session(:sign_in_nonce, nonce)
      |> put_session(:client_platform, "android")
      |> put_session(:client_csrf_token, "foo")

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        secret: "foo",
        client_csrf_token: "xxx"
      })
      |> submit_form(conn)

    assert redirected_to(conn, 302) ==
             ~p"/#{account}/sign_in/providers/email/#{provider}" <>
               "?client_platform=android" <>
               "&client_csrf_token=foo" <>
               "&provider_identifier=#{identity.id}"

    assert conn.assigns.flash["error"] == "The sign in token is invalid or expired."
  end

  test "allows resending sign in link", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      live(conn, ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo")

    assert has_element?(lv, ~s|button[type="submit"]|, "Resend email")

    conn =
      lv
      |> form("#resend-email", %{email: %{provider_identifier: identity.provider_identifier}})
      |> submit_form(conn)

    assert conn.assigns.flash["info"] == "Email was resent."

    assert redirected_to = redirected_to(conn, 302)
    assert redirected_to =~ ~p"/#{account}/sign_in/providers/email/#{provider}"
    assert redirected_to =~ "provider_identifier="
    refute get_session(conn, :client_platform)
  end

  test "does not loose client platform param on email resend", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    conn = put_session(conn, :client_platform, "apple")

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?provider_identifier=foo&client_platform=apple"
      )

    assert has_element?(lv, ~s|button[type="submit"]|, "Resend email")

    conn =
      lv
      |> form("#resend-email", %{
        email: %{provider_identifier: identity.provider_identifier},
        client_platform: "apple"
      })
      |> submit_form(conn)

    assert conn.assigns.flash["info"] == "Email was resent."

    assert redirected_to = redirected_to(conn, 302)
    assert redirected_to =~ ~p"/#{account}/sign_in/providers/email/#{provider}"
    assert redirected_to =~ "provider_identifier="
    assert redirected_to =~ "client_platform=apple"
    assert get_session(conn, :client_platform) == "apple"
  end
end
