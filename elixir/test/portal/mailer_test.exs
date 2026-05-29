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

  describe "deliver/2" do
    test "refreshes ACS HMAC auth headers on Req retries" do
      test_pid = self()
      access_key = Base.encode64("acs-secret")
      adapter_plugin = replace_req_adapter_plugin(test_pid)
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        attempt = Agent.get_and_update(attempts, fn attempt -> {attempt, attempt + 1} end)
        send(test_pid, {:acs_attempt, attempt, acs_auth_headers(conn)})

        case attempt do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "1")
            |> Plug.Conn.put_status(429)
            |> Req.Test.json(%{"error" => %{"message" => "rate limited"}})

          _ ->
            conn
            |> Plug.Conn.put_status(202)
            |> Req.Test.json(%{"id" => "acs-message-123", "status" => "Running"})
        end
      end)

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Test")
        |> Swoosh.Email.text_body("body")
        |> Swoosh.Email.put_private(:client_options,
          retry: :transient,
          max_retries: 1
        )

      assert {:ok, %{id: "acs-message-123", status: "Running"}} =
               deliver(email,
                 adapter: Swoosh.Adapters.AzureCommunicationServices,
                 endpoint: "https://acs.example.com",
                 access_key: access_key,
                 req_opts: [
                   plug: {Req.Test, Portal.AzureCommunicationServices},
                   plugins: [adapter_plugin]
                 ]
               )

      assert_received :replace_req_adapter_plugin_called
      assert_received :replace_req_adapter_plugin_called
      assert_received {:acs_attempt, 0, first_headers}
      assert_received {:acs_attempt, 1, second_headers}
      assert first_headers.x_ms_date != second_headers.x_ms_date
      assert first_headers.authorization != second_headers.authorization
    end
  end

  defp replace_req_adapter_plugin(test_pid) do
    fn req ->
      Req.Request.append_request_steps(req,
        replace_test_adapter: fn req ->
          Map.put(req, :adapter, fn req ->
            send(test_pid, :replace_req_adapter_plugin_called)
            Req.Steps.run_plug(req)
          end)
        end
      )
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
    test "enqueues with a nil account_id when not set" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Missing Account")
        |> Swoosh.Email.text_body("body")

      assert {:ok, job} = enqueue(email)
      assert job.args["account_id"] == nil
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

    test "deduplicates recipients by normalized email address" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.bcc({"", "admin@example.com"})
        |> Swoosh.Email.bcc({"", "Admin@Example.com"})
        |> Swoosh.Email.bcc({"", "admin@example.com"})
        |> Swoosh.Email.bcc({"", "other@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Dedup Test")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, job} = enqueue(email)

      bcc_addresses = Enum.map(job.args["request"]["bcc"], & &1["address"])
      assert length(bcc_addresses) == 2
      assert "admin@example.com" in bcc_addresses
      assert "other@example.com" in bcc_addresses
    end

    test "filters @firezone.invalid recipients before inserting the job" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "missing-email-123@firezone.invalid"})
        |> Swoosh.Email.to({"", "allowed@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Invalid Filtered")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, job} = enqueue(email)
      assert Enum.map(job.args["request"]["to"], & &1["address"]) == ["allowed@example.com"]
    end

    test "skips queueing when all recipients are @firezone.invalid" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "missing-email-123@firezone.invalid"})
        |> Swoosh.Email.bcc({"", "missing-email-456@Firezone.Invalid"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("All Invalid")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, :suppressed} = enqueue(email)
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

  describe "deliver_and_track/2" do
    test "inserts a tracked row when ACS returns a message id, with nil account_id" do
      adapter_plugin = replace_req_adapter_plugin(self())

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-tracked-msg", "status" => "Running"})
      end)

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "tracked@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Sync Tracked")
        |> Swoosh.Email.text_body("body")

      assert {:ok, %{id: "acs-tracked-msg"}} =
               deliver_and_track(email,
                 adapter: Swoosh.Adapters.AzureCommunicationServices,
                 endpoint: "https://acs.example.com",
                 access_key: Base.encode64("acs-secret"),
                 req_opts: [
                   plug: {Req.Test, Portal.AzureCommunicationServices},
                   plugins: [adapter_plugin]
                 ]
               )

      entry = Repo.get!(Portal.OutboundEmail, "acs-tracked-msg")
      assert entry.account_id == nil
      assert entry.subject == "Sync Tracked"
      assert entry.recipients == ["tracked@example.com"]

      delivery =
        Repo.get_by!(Portal.OutboundEmailDelivery,
          message_id: "acs-tracked-msg",
          email: "tracked@example.com"
        )

      assert delivery.status == :pending
      assert delivery.account_id == nil
    end

    test "associates account_id when set via with_account_id/2" do
      account = account_fixture()
      adapter_plugin = replace_req_adapter_plugin(self())

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-tracked-account-msg", "status" => "Running"})
      end)

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "tracked@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Sync Tracked Account")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, %{id: "acs-tracked-account-msg"}} =
               deliver_and_track(email,
                 adapter: Swoosh.Adapters.AzureCommunicationServices,
                 endpoint: "https://acs.example.com",
                 access_key: Base.encode64("acs-secret"),
                 req_opts: [
                   plug: {Req.Test, Portal.AzureCommunicationServices},
                   plugins: [adapter_plugin]
                 ]
               )

      entry = Repo.get!(Portal.OutboundEmail, "acs-tracked-account-msg")
      assert entry.account_id == account.id
    end

    test "does not insert a tracked row when the adapter response has no message id" do
      account = account_fixture()

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"", "recipient@example.com"})
        |> Swoosh.Email.from({"", "sender@example.com"})
        |> Swoosh.Email.subject("Untracked")
        |> Swoosh.Email.text_body("body")
        |> with_account_id(account.id)

      assert {:ok, %{}} = deliver_and_track(email)
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
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

  defp acs_auth_headers(conn) do
    %{
      authorization: request_header(conn, "authorization"),
      x_ms_date: request_header(conn, "x-ms-date")
    }
  end

  defp request_header(conn, name) do
    name = String.downcase(name)

    Enum.find_value(conn.req_headers, fn {header_name, value} ->
      if String.downcase(header_name) == name, do: value
    end)
  end
end
