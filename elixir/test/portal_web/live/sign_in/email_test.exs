defmodule PortalWeb.SignIn.EmailTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias PortalWeb.Cookie.EmailOTP

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

  describe "mount without auth state" do
    test "redirects back to sign-in when no email session cookie",
         %{conn: conn, account: account, provider: provider} do
      path = ~p"/#{account}/sign_in/email_otp/#{provider}"

      assert {:error, {:live_redirect, %{to: _}}} = live(conn, path)
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
  end
end
