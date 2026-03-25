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
    test "should contain sync error info", %{directory: directory} do
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
  end
end
