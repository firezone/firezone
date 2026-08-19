defmodule Portal.Mailer.SyncErrorEmailTest do
  use Portal.DataCase, async: true
  import Portal.Mailer.SyncEmail
  import Portal.AccountFixtures
  import Portal.OktaDirectoryFixtures

  setup do
    account = account_fixture()
    okta_dir = okta_directory_fixture(account: account)
    okta_dir_with_account = Repo.preload(okta_dir, :account)

    %{
      account: account,
      directory: okta_dir_with_account
    }
  end

  describe "sync_error_email/2" do
    test "should contain sync error info", %{account: account, directory: directory} do
      admin_email = "admin@foo.local"
      expected_msg = "403 - Forbidden"

      directory =
        directory
        |> Ecto.Changeset.change(error_message: expected_msg, errored_at: DateTime.utc_now())
        |> Repo.update!()

      directory = Repo.preload(directory, :account)

      email_body = sync_error_email(directory, admin_email)

      assert email_body.text_body =~ expected_msg
      assert email_body.text_body =~ directory.name
      assert email_body.text_body =~ "/#{account.slug}/settings/directory_sync"
      refute email_body.text_body =~ "/#{account.id}/settings/directory_sync"
    end

    test "email is addressed to the admin email", %{directory: directory} do
      admin_email = "admin@example.com"

      directory =
        directory
        |> Ecto.Changeset.change(error_message: "Sync failed")
        |> Repo.update!()

      directory = Repo.preload(directory, :account)

      email_body = sync_error_email(directory, admin_email)

      assert email_body.to == [{"", admin_email}]
    end

    test "email subject includes directory name", %{directory: directory} do
      directory = Repo.preload(directory, :account)
      email_body = sync_error_email(directory, "admin@example.com")

      assert email_body.subject =~ "Directory Sync Error"
      assert email_body.subject =~ directory.name
    end

    test "plain text body opens with the error headline", %{directory: directory} do
      directory = Repo.preload(directory, :account)
      email_body = sync_error_email(directory, "admin@example.com")

      assert String.starts_with?(email_body.text_body, "#{directory.name} Sync Error!")
    end
  end

  describe "posture_provider_error_email/2" do
    setup %{account: account} do
      provider =
        [account: account]
        |> Portal.IntuneFixtures.intune_posture_provider_fixture()
        |> Ecto.Changeset.change(
          error_message: "403 - Forbidden",
          errored_at: DateTime.utc_now()
        )
        |> Repo.update!()
        |> Repo.preload(:account)

      %{provider: provider}
    end

    test "plain text body opens with the error headline", %{provider: provider} do
      email_body = posture_provider_error_email(provider, "admin@example.com")

      assert String.starts_with?(email_body.text_body, "#{provider.name} Sync Error!")
    end

    test "body contains the sync error, tenant and settings link", %{
      account: account,
      provider: provider
    } do
      email_body = posture_provider_error_email(provider, "admin@example.com")

      assert email_body.text_body =~ "403 - Forbidden"
      assert email_body.text_body =~ ~r/Tenant ID:\s*#{provider.tenant_id}/
      assert email_body.text_body =~ "/#{account.slug}/settings/device_posture"
      refute email_body.text_body =~ "/#{account.id}/settings/device_posture"
    end

    test "email subject includes the provider name", %{provider: provider} do
      email_body = posture_provider_error_email(provider, "admin@example.com")

      assert email_body.subject =~ provider.name
    end

    test "an Iru provider names its tenant by subdomain and region", %{account: account} do
      provider =
        [account: account, region: :eu]
        |> Portal.IruFixtures.iru_posture_provider_fixture()
        |> Ecto.Changeset.change(
          error_message: "401 - Invalid token.",
          errored_at: DateTime.utc_now()
        )
        |> Repo.update!()
        |> Repo.preload(:account)

      email_body = posture_provider_error_email(provider, "admin@example.com")

      assert email_body.text_body =~ "401 - Invalid token."
      assert email_body.text_body =~ ~r/Subdomain:\s*#{provider.subdomain}/
      assert email_body.text_body =~ ~r/Region:\s*EU/
      assert email_body.text_body =~ "Iru API token"
    end
  end
end
