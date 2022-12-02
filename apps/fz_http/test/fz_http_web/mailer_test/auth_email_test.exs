defmodule FzHttpWeb.AuthEmailTest do
  use FzHttpWeb.MailerCase, async: true

  alias FzHttp.Users

  describe "reset_sign_in_token/1" do
    setup :create_user

    import Swoosh.TestAssertions

    test "when email exists sends a magic link", %{user: user} do
      Users.reset_sign_in_token(user.email)

      user = Users.get_user!(user.id)

      assert_email_sent(
        subject: "Firezone Magic Link",
        to: [{"", user.email}],
        text_body: ~r(#{url(~p"/auth/magic/#{user.sign_in_token}")})
      )
    end

    test "when email does not exist logs the attempt" do
      Users.reset_sign_in_token("foobar@example.com")
      refute_email_sent()
    end
  end
end
