defmodule Web.SignIn.EmailTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)
    actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
    context = Fixtures.Auth.build_context()

    {:ok, identity} =
      Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
      |> Domain.Auth.Adapters.Email.request_sign_in_token(context)

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
    identity: identity,
    conn: conn
  } do
    {conn, _secret} = put_email_auth_state(conn, account, provider, identity)

    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    {:ok, lv, html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?signed_provider_identifier=#{signed_provider_identifier}"
      )

    assert html =~ "Please check your email"
    assert has_element?(lv, ~s|a[href="https://mail.google.com/mail/"]|, "Open Gmail")
    assert has_element?(lv, ~s|a[href="https://outlook.live.com/mail/"]|, "Open Outlook")
  end

  test "redirects browser after sign in", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {conn, secret} = put_email_auth_state(conn, account, provider, identity)

    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?signed_provider_identifier=#{signed_provider_identifier}&as=client&state=STATE&nonce=NONCE"
      )

    assert has_element?(lv, ~s|form#verify-sign-in-token|)
    assert has_element?(lv, "button", "Submit")

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        as: "client",
        state: "STATE",
        nonce: "NONCE",
        secret: secret
      })
      |> submit_form(conn)

    assert redirected_to(conn, 302) == ~p"/#{account}/sites"
    refute conn.assigns.flash["error"]
  end

  test "redirects client after sign in", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    redirect_params = %{
      "as" => "client",
      "state" => "STATE",
      "nonce" => "NONCE",
      "redirect_to" => "/foo"
    }

    {conn, secret} = put_email_auth_state(conn, account, provider, identity, redirect_params)

    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?signed_provider_identifier=#{signed_provider_identifier}"
      )

    assert has_element?(lv, ~s|form#verify-sign-in-token|)
    assert has_element?(lv, "button", "Submit")

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        as: "client",
        state: "STATE",
        nonce: "NONCE",
        secret: secret
      })
      |> submit_form(conn)

    assert response = response(conn, 200)
    assert response =~ "Sign in successful"
    refute conn.assigns.flash["error"]
  end

  test "renders error on invalid secret", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {conn, _secret} = put_email_auth_state(conn, account, provider, identity)

    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?signed_provider_identifier=#{signed_provider_identifier}&client_platform=android"
      )

    conn =
      lv
      |> form("#verify-sign-in-token", %{
        identity_id: identity.id,
        secret: "foo"
      })
      |> submit_form(conn)

    assert uri = conn |> redirected_to(302) |> URI.parse()
    assert uri.path == ~p"/#{account}/sign_in/providers/email/#{provider}"

    assert %{"signed_provider_identifier" => signed_provider_identifier} =
             URI.decode_query(uri.query)

    assert Plug.Crypto.verify(
             conn.secret_key_base,
             "signed_provider_identifier",
             signed_provider_identifier
           ) == {:ok, identity.provider_identifier}

    assert conn.assigns.flash["error"] == "The sign in token is invalid or expired."
  end

  test "allows resending sign in link", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/#{account}/sign_in/providers/email/#{provider}?signed_provider_identifier=#{signed_provider_identifier}"
      )

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

  test "does not loose redirect params on email resend", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    signed_provider_identifier =
      Plug.Crypto.sign(
        conn.secret_key_base,
        "signed_provider_identifier",
        identity.provider_identifier
      )

    redirect_params = %{
      "as" => "client",
      "state" => "STATE",
      "nonce" => "NONCE",
      "redirect_to" => "/foo",
      "signed_provider_identifier" => signed_provider_identifier
    }

    {:ok, lv, _html} =
      live(conn, ~p"/#{account}/sign_in/providers/email/#{provider}?#{redirect_params}")

    assert has_element?(lv, ~s|button[type="submit"]|, "Resend email")

    conn =
      lv
      |> form("#resend-email", %{
        email: %{provider_identifier: identity.provider_identifier},
        as: "client",
        state: "STATE",
        nonce: "NONCE",
        redirect_to: "/foo"
      })
      |> submit_form(conn)

    assert conn.assigns.flash["info"] == "Email was resent."

    assert redirected_to = redirected_to(conn, 302)
    assert redirected_to =~ ~p"/#{account}/sign_in/providers/email/#{provider}"
    assert redirected_to =~ "provider_identifier="
    assert redirected_to =~ "as=client"
    assert redirected_to =~ "nonce=NONCE"
    assert redirected_to =~ "state=STATE"
    assert redirected_to =~ "redirect_to=%2Ffoo"
  end
end
