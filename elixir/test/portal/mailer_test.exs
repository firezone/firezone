defmodule Portal.MailerTest do
  use Portal.DataCase, async: true

  import Ecto.Query
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

  describe "with_account/2" do
    test "sets account_id in email private" do
      email = Swoosh.Email.new()
      account = account_fixture()

      result = with_account(email, account.id)

      assert result.private[:account_id] == account.id
    end

    test "accepts an account struct" do
      email = Swoosh.Email.new()
      account = account_fixture()

      result = with_account(email, account)

      assert result.private[:account_id] == account.id
    end
  end

  describe "enqueue/2 with :later priority" do
    test "raises when account_id is missing" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Missing Account")
        |> Swoosh.Email.text_body("body")

      assert_raise ArgumentError, ~r/with_account\/2/, fn ->
        enqueue(email, :later)
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
        |> with_account(account.id)

      assert {:ok, job} = enqueue(email, :later)

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
        |> with_account(account.id)

      assert {:ok, job} = enqueue(email, :later)
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
        |> with_account(account.id)

      assert {:ok, :suppressed} = enqueue(email, :later)
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
        |> with_account(account.id)

      assert {:ok, :suppressed} = enqueue(email, :later)
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
        |> with_account(account.id)

      assert {:ok, job} = enqueue(email, :later)
      assert job.args["request"]["bcc"] == [%{"name" => "", "address" => "allowed@example.com"}]
    end
  end

  describe "enqueue/2 with :now priority" do
    test "returns the inline deliver result without creating a tracked row when no message id is returned" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Now Test")
        |> Swoosh.Email.text_body("now body")
        |> with_account(account.id)

      assert {:ok, %{}} = enqueue(email, :now)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0

      assert_email_sent(subject: "Now Test")
    end

    test "returns inline delivery errors without creating a tracked row" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.subject("Now Failed")
        |> Swoosh.Email.text_body("now body")
        |> with_account(account.id)

      assert {:error, :from_not_set} = enqueue(email, :now)
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
        |> with_account(account.id)

      assert {:ok, %{}} = enqueue(email, :now)
      assert_email_sent(subject: "Bypass")
    end

    test "deduplicates tracked recipients by normalized email" do
      account = account_fixture()
      now = DateTime.utc_now()

      request = %{
        "to" => [%{"name" => "", "address" => "Recipient@example.com"}],
        "cc" => [%{"name" => "", "address" => " recipient@example.com "}],
        "bcc" => [],
        "from" => %{"name" => "", "address" => "sender@example.com"},
        "subject" => "Tracked",
        "html_body" => nil,
        "text_body" => "body"
      }

      assert {:ok, entry} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 :later,
                 "acs-message-123",
                 request,
                 %{"id" => "acs-message-123", "status" => "Running", "at" => now}
               )

      assert entry.account_id == account.id
      assert entry.message_id == "acs-message-123"

      recipients =
        from(r in Portal.OutboundEmailRecipient,
          where: r.account_id == ^account.id,
          where: r.message_id == ^entry.message_id,
          order_by: [asc: r.email]
        )
        |> Repo.all()

      assert Enum.map(recipients, & &1.email) == ["recipient@example.com"]
      assert Enum.map(recipients, & &1.status) == [:pending]
    end

    test "returns an error when the same message id is tracked twice" do
      account = account_fixture()

      request = %{
        "to" => [%{"name" => "", "address" => "recipient@example.com"}],
        "cc" => [],
        "bcc" => [],
        "from" => %{"name" => "", "address" => "sender@example.com"},
        "subject" => "Tracked",
        "html_body" => nil,
        "text_body" => "body"
      }

      assert {:ok, _entry} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 :later,
                 "acs-message-duplicate",
                 request,
                 %{"id" => "acs-message-duplicate", "status" => "Running"}
               )

      assert {:error, changeset} =
               Portal.Mailer.Database.insert_tracked(
                 account.id,
                 :later,
                 "acs-message-duplicate",
                 request,
                 %{"id" => "acs-message-duplicate", "status" => "Running"}
               )

      refute changeset.valid?
    end
  end
end
