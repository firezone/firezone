defmodule Web.Auth.EmailTest do
  use Web.ConnCase, async: true

  test "renders email page", %{conn: conn} do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_email_provider(account: account)

    {:ok, lv, html} =
      live(conn, ~p"/#{account}/providers/email/#{provider}?provider_identifier=foo")

    assert html =~ "Please check your email"
    assert has_element?(lv, ~s|a[href="https://mail.google.com/mail/"]|, "Open Gmail")
    assert has_element?(lv, ~s|a[href="https://outlook.live.com/mail/"]|, "Open Outlook")
  end
end
