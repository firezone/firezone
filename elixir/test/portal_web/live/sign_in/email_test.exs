defmodule PortalWeb.SignIn.EmailTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  setup do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()
    provider = email_otp_provider_fixture(account: account)

    actor =
      actor_fixture(account: account, type: :account_admin_user, allow_email_otp_sign_in: true)

    %{
      account: account,
      provider: provider,
      actor: actor
    }
  end

  defp setup_email_otp_cookie(conn, account, provider, actor) do
    # Post to sign_in to send OTP and get the email_otp cookie
    redirected_conn =
      post(conn, ~p"/#{account}/sign_in/email_otp/#{provider.id}", %{
        "email" => %{"email" => actor.email}
      })

    assert_received {:email, email}
    [_match, secret] = Regex.run(~r/secret=([^&\n]*)/, email.text_body)

    cookie_key = "email_otp"
    %{value: signed_value} = redirected_conn.resp_cookies[cookie_key]

    conn_with_cookie = put_req_cookie(conn, cookie_key, signed_value)

    {conn_with_cookie, secret}
  end

  test "renders delivery confirmation page", %{
    account: account,
    provider: provider,
    actor: actor,
    conn: conn
  } do
    {conn_with_cookie, _secret} = setup_email_otp_cookie(conn, account, provider, actor)

    {:ok, _lv, html} =
      live(conn_with_cookie, ~p"/#{account}/sign_in/email_otp/#{provider.id}")

    assert html =~ "Please check your email"
    assert html =~ "Open Gmail"
    assert html =~ "Open Outlook"
  end

  test "shows sign-in code input form", %{
    account: account,
    provider: provider,
    actor: actor,
    conn: conn
  } do
    {conn_with_cookie, _secret} = setup_email_otp_cookie(conn, account, provider, actor)

    {:ok, lv, _html} =
      live(conn_with_cookie, ~p"/#{account}/sign_in/email_otp/#{provider.id}")

    assert has_element?(lv, ~s|form#verify-sign-in-token|)
    assert has_element?(lv, "button", "Submit")
  end

  test "redirects when cookie is missing", %{
    account: account,
    provider: provider,
    conn: conn
  } do
    assert {:error, {:live_redirect, %{flash: %{"error" => error_msg}}}} =
             live(conn, ~p"/#{account}/sign_in/email_otp/#{provider.id}")

    assert error_msg =~ "Please try to sign in again."
  end
end
