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
  end

  describe "enqueue/2 with :later priority" do
    test "inserts a pending row without delivering" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Test")
        |> Swoosh.Email.text_body("body")
        |> with_account(account.id)

      assert {:ok, entry} = enqueue(email, :later)

      assert entry.status == :pending
      assert entry.priority == :later
      assert is_nil(entry.last_attempted_at)

      recipients = queued_recipients!(entry.id)

      assert Enum.map(recipients, &{&1.kind, &1.email, &1.status}) == [
               {:to, "recipient@example.com", :pending}
             ]

      refute_email_sent()
    end

    test "filters suppressed recipients before inserting the queue row" do
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

      assert {:ok, entry} = enqueue(email, :later)

      assert Enum.map(entry.request["to"], & &1["address"]) == ["allowed@example.com"]
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
      assert Repo.aggregate(Portal.OutboundEmail, :count, :id) == 0
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
      assert Repo.aggregate(Portal.OutboundEmail, :count, :id) == 0
    end

    test "filters suppressed bcc recipients before inserting recipient rows" do
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

      assert {:ok, entry} = enqueue(email, :later)
      assert entry.request["bcc"] == [%{"name" => "", "address" => "allowed@example.com"}]

      recipients = queued_recipients!(entry.id)
      assert Enum.map(recipients, &{&1.kind, &1.email}) == [{:bcc, "allowed@example.com"}]
    end
  end

  describe "enqueue/2 with :now priority" do
    test "returns the inline deliver result and keeps recipient deliverability pending" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Now Test")
        |> Swoosh.Email.text_body("now body")
        |> with_account(account.id)

      assert {:ok, %{}} = enqueue(email, :now)

      db_entry = queued_entry!()
      assert db_entry.status == :running
      assert db_entry.last_attempted_at != nil

      recipients = queued_recipients!(db_entry.id)
      assert Enum.map(recipients, & &1.status) == [:pending]

      assert_email_sent(subject: "Now Test")
    end

    test "returns inline delivery errors while leaving recipient deliverability pending" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.subject("Now Failed")
        |> Swoosh.Email.text_body("now body")
        |> with_account(account.id)

      assert {:error, :from_not_set} = enqueue(email, :now)

      db_entry = queued_entry!()
      assert db_entry.status == :errored
      assert db_entry.response["reason"] =~ ":from_not_set"

      recipients = queued_recipients!(db_entry.id)
      assert Enum.map(recipients, & &1.status) == [:pending]
    end

    test "sets last_attempted_at before delivery so worker skips mid-delivery rows" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Now Locked")
        |> Swoosh.Email.text_body("locked")
        |> with_account(account.id)

      assert {:ok, %{}} = enqueue(email, :now)

      # After delivery, last_attempted_at is set — worker's filter (is_nil OR > 5min ago) skips it
      db_entry = queued_entry!()
      assert db_entry.last_attempted_at != nil
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
  end

  defp queued_entry! do
    from(e in Portal.OutboundEmail, order_by: [desc: e.inserted_at], limit: 1)
    |> Repo.one!()
  end

  defp queued_recipients!(outbound_email_id) do
    from(r in Portal.OutboundEmailRecipient,
      where: r.outbound_email_id == ^outbound_email_id,
      order_by: [asc: r.kind, asc: r.email]
    )
    |> Repo.all()
  end
end
