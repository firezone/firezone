defmodule PortalWeb.SignIn.EmailTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias PortalWeb.Cookie.{EmailOTP, PendingIdentity}

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    provider = email_otp_provider_fixture(account: account)

    %{account: account, actor: actor, provider: provider}
  end

  defp put_email_otp_cookie(conn, actor_id, email) do
    cookie = %EmailOTP{
      actor_id: actor_id,
      passcode_id: Ecto.UUID.generate(),
      email: email
    }

    conn
    |> EmailOTP.put(cookie)
    |> then(fn c -> put_req_cookie(c, "email_otp", c.resp_cookies["email_otp"].value) end)
  end

  defp put_pending_identity_cookie(conn, params \\ %{}) do
    pending_identity_id = Ecto.UUID.generate()
    cookie = %PendingIdentity{pending_identity_id: pending_identity_id, params: params}
    cookie_key = "pending_identity_#{pending_identity_id}"

    conn =
      conn
      |> PendingIdentity.put(cookie)
      |> then(fn c -> put_req_cookie(c, cookie_key, c.resp_cookies[cookie_key].value) end)

    {conn, pending_identity_id}
  end

  describe "mount without auth state" do
    test "redirects back to sign-in when no email session cookie",
         %{conn: conn, account: account, provider: provider} do
      path = ~p"/#{account}/sign_in/email_otp/#{provider}"

      assert {:error, {:redirect, %{to: _}}} = live(conn, path)
    end
  end

  describe "mount with auth state" do
    test "renders OTP entry form with email",
         %{conn: conn, account: account, actor: actor, provider: provider} do
      conn = put_email_otp_cookie(conn, actor.id, actor.email)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in/email_otp/#{provider}")

      assert html =~ "Check your email"
      assert html =~ actor.email
    end

    test "renders resend and different method buttons",
         %{conn: conn, account: account, actor: actor, provider: provider} do
      conn = put_email_otp_cookie(conn, actor.id, actor.email)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in/email_otp/#{provider}")

      assert html =~ "Resend email"
      assert html =~ "Different method"
    end

    test "renders pending identity verification form without loading email",
         %{conn: conn, account: account, actor: actor} do
      provider = oidc_provider_fixture(account: account)
      {conn, pending_identity_id} = put_pending_identity_cookie(conn)

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{account}/sign_in/oidc/#{provider}/verify_identity?pending_identity_id=#{pending_identity_id}"
        )

      assert html =~ "Check your email"
      assert html =~ "A verification code has been sent to your email address."
      assert html =~ "pending_identity_id=#{pending_identity_id}"
      refute html =~ actor.email
      refute html =~ "Resend email"
    end

    test "uses pending identity cookie params for verification form context",
         %{conn: conn, account: account} do
      provider = oidc_provider_fixture(account: account)

      {conn, pending_identity_id} =
        put_pending_identity_cookie(conn, %{
          "as" => "gui-client",
          "state" => "original-state",
          "nonce" => "original-nonce",
          "redirect_to" => "/#{account.slug}/actors"
        })

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{account}/sign_in/oidc/#{provider}/verify_identity?pending_identity_id=#{pending_identity_id}&as=headless-client&state=submitted-state"
        )

      assert html =~ "as\" value=\"gui-client"
      assert html =~ "state\" value=\"original-state"
      assert html =~ "nonce\" value=\"original-nonce"
      assert html =~ "redirect_to\" value=\"/#{account.slug}/actors"
      refute html =~ "headless-client"
      refute html =~ "submitted-state"
    end
  end
end
