defmodule Domain.Mailer.AccountDeleteEmailTest do
  use Domain.DataCase, async: true
  import Domain.Mailer.AccountDelete

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      subject: subject
    }
  end

  describe "account_delete_email/2" do
    test "should contain account info", %{account: account, subject: subject} do
      email_body = account_delete_email(account, subject)

      assert email_body.text_body =~ "REQUEST TO DELETE ACCOUNT!"
      assert email_body.text_body =~ ~r/Account ID:\s*#{account.id}/
      assert email_body.text_body =~ ~r/Actor ID:\s*#{subject.actor.id}/
      assert email_body.text_body =~ ~r/Identifier:\s*#{subject.identity.provider_identifier}/
    end
  end
end
