defmodule Portal.Mailer.FeedbackEmailTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SubjectFixtures

  alias Portal.Config
  alias Portal.Mailer.FeedbackEmail

  test "uses the configured recipient" do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    subject = subject_fixture(actor: actor, account: account)
    Config.put_env_override(:portal, FeedbackEmail, recipient: "feedback@example.com")

    email = FeedbackEmail.feedback_email(subject, "Feedback", "https://app.firezone.dev/")

    assert email.to == [{"", "feedback@example.com"}]
    assert email.subject == "In-portal feedback submission"
  end

  for key <- [:feedback_email_recipient, :posture_provider_interest_email_recipient] do
    test "#{key} is optional and validates configured addresses" do
      key = unquote(key)
      env = key |> Atom.to_string() |> String.upcase()
      assert is_nil(Config.env_var_to_config!(Config.Definitions, key, %{}))

      for value <- ["", "   "] do
        assert is_nil(Config.env_var_to_config!(Config.Definitions, key, %{env => value}))
      end

      assert Config.env_var_to_config!(Config.Definitions, key, %{env => " feedback@example.com "}) ==
               "feedback@example.com"

      assert_raise RuntimeError, fn ->
        Config.env_var_to_config!(Config.Definitions, key, %{env => "not-an-email"})
      end
    end
  end
end
