defmodule Portal.Mailer.AccountDeleteEmailTest do
  use Portal.DataCase, async: true
  import Portal.Mailer.AccountDelete
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SubjectFixtures

  setup do
    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    subject = subject_fixture(actor: actor, account: account)

    %{
      account: account,
      subject: subject
    }
  end

  describe "account_delete_email/2" do
    test "should contain account info", %{account: account, subject: subject} do
      email_body = account_delete_email(account, subject)

      assert email_body.text_body =~ "Request to Delete Account"
      assert email_body.text_body =~ ~r/Account ID:\s*#{account.id}/
      assert email_body.text_body =~ ~r/Actor ID:\s*#{subject.actor.id}/
    end
  end
end
