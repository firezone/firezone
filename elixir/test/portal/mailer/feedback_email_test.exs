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

  test "recipient configuration defaults to support and accepts an environment override" do
    assert Config.env_var_to_config!(Config.Definitions, :feedback_email_recipient, %{}) ==
             "support@firezone.dev"

    assert Config.env_var_to_config!(Config.Definitions, :feedback_email_recipient, %{
             "FEEDBACK_EMAIL_RECIPIENT" => "feedback@example.com"
           }) == "feedback@example.com"
  end

  test "rejects invalid or blank recipient configuration" do
    for recipient <- ["not-an-email", " "] do
      assert_raise RuntimeError, fn ->
        Config.env_var_to_config!(Config.Definitions, :feedback_email_recipient, %{
          "FEEDBACK_EMAIL_RECIPIENT" => recipient
        })
      end
    end
  end
end
