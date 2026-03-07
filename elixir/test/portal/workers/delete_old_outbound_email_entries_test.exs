defmodule Portal.Workers.DeleteOldOutboundEmailEntriesTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.Mailer
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.Workers.DeleteOldOutboundEmailEntries

  describe "perform/1" do
    test "deletes entries older than 30 days" do
      account = account_fixture()
      entry = outbound_email_fixture(account)

      entry
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-31, :day))
      |> Repo.update!()

      assert Repo.get_by(Portal.OutboundEmail, id: entry.id)

      assert :ok = perform_job(DeleteOldOutboundEmailEntries, %{})

      refute Repo.get_by(Portal.OutboundEmail, id: entry.id)
    end

    test "does not delete entries newer than 30 days" do
      account = account_fixture()
      entry = outbound_email_fixture(account)

      assert Repo.get_by(Portal.OutboundEmail, id: entry.id)

      assert :ok = perform_job(DeleteOldOutboundEmailEntries, %{})

      assert Repo.get_by(Portal.OutboundEmail, id: entry.id)
    end

    test "deletes across multiple accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      entry1 = outbound_email_fixture(account1)
      entry2 = outbound_email_fixture(account2)

      for entry <- [entry1, entry2] do
        entry
        |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-31, :day))
        |> Repo.update!()
      end

      assert :ok = perform_job(DeleteOldOutboundEmailEntries, %{})

      refute Repo.get_by(Portal.OutboundEmail, id: entry1.id)
      refute Repo.get_by(Portal.OutboundEmail, id: entry2.id)
    end

    test "deletes recipient rows through the queue row foreign key" do
      account = account_fixture()

      email =
        default_email()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.subject("Delete Queue Row")
        |> Swoosh.Email.text_body("body")
        |> with_account(account.id)

      assert {:ok, entry} = enqueue(email, :later)

      entry
      |> Ecto.Changeset.change(inserted_at: DateTime.utc_now() |> DateTime.add(-31, :day))
      |> Repo.update!()

      assert Repo.aggregate(Portal.OutboundEmailRecipient, :count, :id) == 1

      assert :ok = perform_job(DeleteOldOutboundEmailEntries, %{})

      refute Repo.get_by(Portal.OutboundEmail, id: entry.id)
      assert Repo.aggregate(Portal.OutboundEmailRecipient, :count, :id) == 0
    end
  end
end
