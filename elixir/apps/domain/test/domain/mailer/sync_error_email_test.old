defmodule Domain.Mailer.SyncErrorEmailTest do
  use Domain.DataCase, async: true
  import Domain.Mailer.SyncEmail

  setup do
    account = Fixtures.Accounts.create_account()
    {provider, _bypass} = Fixtures.Auth.start_and_create_okta_provider(account: account)

    %{
      account: account,
      provider: provider
    }
  end

  describe "sync_error_email/2" do
    test "should contain sync error info", %{provider: provider} do
      admin_email = "admin@foo.local"
      expected_msg = "403 - Forbidden"

      provider =
        provider
        |> Domain.Repo.preload(:account)
        |> set_provider_failure("Error while syncing")
        |> set_provider_failure(expected_msg)

      email_body = sync_error_email(provider, admin_email)

      assert email_body.text_body =~ "2 time(s)"
      assert email_body.text_body =~ expected_msg
    end
  end

  defp set_provider_failure(provider, message) do
    Domain.AuthProvider.Changeset.sync_failed(provider, message)
    |> Domain.Repo.update!()
  end
end
