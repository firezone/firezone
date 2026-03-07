defmodule Portal.MailerTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.Mailer

  describe "deliver_with_rate_limit/2" do
    test "delivers email with rate limit" do
      email = %Swoosh.Email{to: "foo@bar.com", subject: "Hello"}
      config = [rate_limit: 10, rate_limit_interval: :timer.minutes(2)]

      assert deliver_with_rate_limit(email, config) == {:error, :from_not_set}
    end

    test "does not deliver email when it's rate limited" do
      email = %Swoosh.Email{to: "foo@bar.com", subject: "World"}
      config = [rate_limit: 1, rate_limit_interval: :timer.minutes(2)]

      assert deliver_with_rate_limit(email, config) == {:error, :from_not_set}
      assert deliver_with_rate_limit(email, config) == {:error, :rate_limited}
    end
  end

  describe "with_account_id/2" do
    test "sets account_id in email private" do
      email = Swoosh.Email.new()
      account = account_fixture()

      result = with_account_id(email, account.id)

      assert result.private[:account_id] == account.id
    end
  end

  describe "enqueue/1" do
    test "raises when account_id is missing" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Missing Account")
        |> Swoosh.Email.text_body("body")

      assert_raise ArgumentError, ~r/with_account_id\/2/, fn ->
        enqueue(email)
      end
    end

    test "enqueues an Oban job without delivering" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Test")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, job} = enqueue(email)

      assert job.worker == "Portal.Workers.OutboundEmail"
      assert job.args["account_id"] == account.id
      assert job.args["request"]["subject"] == "Test"
      assert job.args["request"]["to"] == [%{"name" => "", "address" => "recipient@example.com"}]
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0

      refute_email_sent()
    end

    test "filters suppressed recipients before inserting the job" do
      account = account_fixture()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("suppressed@example.com")
      })

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "suppressed@example.com"})
        |> Swoosh.Email.to({"", "allowed@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Filtered")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, job} = enqueue(email)
      assert Enum.map(job.args["request"]["to"], & &1["address"]) == ["allowed@example.com"]
    end

    test "skips queueing when all recipients are suppressed" do
      account = account_fixture()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("suppressed@example.com")
      })

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "suppressed@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Suppressed")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, :suppressed} = enqueue(email)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
      assert Repo.aggregate(Oban.Job, :count, :id) == 0
    end

    test "does not queue a later email when the recipient is in suppressions" do
      account = account_fixture()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("recipient@example.com")
      })

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", " Recipient@Example.com "})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Suppressed Recipient")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, :suppressed} = enqueue(email)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
      assert Repo.aggregate(Oban.Job, :count, :id) == 0
    end

    test "filters suppressed bcc recipients before inserting the job" do
      account = account_fixture()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("suppressed@example.com")
      })

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.bcc({"", "suppressed@example.com"})
        |> Swoosh.Email.bcc({"", "allowed@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Filtered BCC")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, job} = enqueue(email)
      assert job.args["request"]["bcc"] == [%{"name" => "", "address" => "allowed@example.com"}]
    end
  end

  describe "deliver/1" do
    test "delivers email inline without creating a tracked row" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Now Test")
        |> Swoosh.Email.text_body("now body")
        |> with_account_id(account.id)

      assert {:ok, %{}} = deliver(email)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0

      assert_email_sent(subject: "Now Test")
    end

    test "returns delivery errors" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.subject("Now Failed")
        |> Swoosh.Email.text_body("now body")
        |> with_account_id(account.id)

      assert {:error, :from_not_set} = deliver(email)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "bypasses the suppression table" do
      account = account_fixture()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("recipient@example.com")
      })

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Bypass")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, %{}} = deliver(email)
      assert_email_sent(subject: "Bypass")
    end
  end

  describe "Database.insert_tracked/4" do
    test "stores subject and recipients in the tracked row" do
      account = account_fixture()

      assert {:ok, entry} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 "acs-message-123",
                 "Tracked",
                 ["recipient@example.com"]
               )

      assert entry.account_id == account.id
      assert entry.message_id == "acs-message-123"
      assert entry.subject == "Tracked"
      assert entry.recipients == ["recipient@example.com"]
    end

    test "returns an error when the same message id is tracked twice" do
      account = account_fixture()

      assert {:ok, _entry} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 "acs-message-duplicate",
                 "Tracked",
                 ["recipient@example.com"]
               )

      assert {:error, changeset} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 "acs-message-duplicate",
                 "Tracked",
                 ["recipient@example.com"]
               )

      refute changeset.valid?
    end
  end
end
