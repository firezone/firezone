defmodule Portal.Mailer.PostureProviderInterestEmailTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SubjectFixtures

  alias Portal.Mailer.PostureProviderInterestEmail

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    subject = subject_fixture(actor: actor, account: account)

    %{account: account, actor: actor, subject: subject}
  end

  test "builds an interest email for engineering", context do
    email = PostureProviderInterestEmail.interest_email(context.subject, "Jamf Pro")

    assert email.to == [{"", "engineering@firezone.dev"}]
    assert email.subject == "Posture Provider interest"
    assert email.text_body =~ "Actor ID: #{context.actor.id}"
    assert email.text_body =~ "Account ID: #{context.account.id}"
    assert email.text_body =~ "Provider: Jamf Pro"
    refute email.text_body =~ "Feedback:"
  end

  test "builds a separate feedback email for engineering", context do
    email =
      PostureProviderInterestEmail.feedback_email(
        context.subject,
        "Workspace ONE",
        "We need device compliance and encryption status."
      )

    assert email.to == [{"", "engineering@firezone.dev"}]
    assert email.subject == "Posture Provider interest"
    assert email.text_body =~ "Actor ID: #{context.actor.id}"
    assert email.text_body =~ "Account ID: #{context.account.id}"
    assert email.text_body =~ "Provider: Workspace ONE"
    assert email.text_body =~ "Feedback:\nWe need device compliance and encryption status."
  end
end
