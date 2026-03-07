defmodule Portal.Workers.OutboundEmailTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.Workers.OutboundEmail, as: Worker

  describe "perform/1" do
    test "delivers a pending :later entry and marks it running" do
      account = account_fixture()
      entry = outbound_email_fixture(account, priority: :later, status: :pending)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :running
      assert db_entry.last_attempted_at != nil
      assert_email_sent()
    end

    test "retries an :errored entry whose last_attempted_at is older than 5 minutes" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :errored,
          last_attempted_at: DateTime.utc_now() |> DateTime.add(-6, :minute)
        )

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :running
      assert_email_sent()
    end

    test "skips an :errored entry with recent last_attempted_at" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :errored,
          last_attempted_at: DateTime.utc_now() |> DateTime.add(-2, :minute)
        )

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :errored
      refute_email_sent()
    end

    test "ignores :now rows" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :now,
          status: :pending
        )

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :pending
      refute_email_sent()
    end

    test "does not let :now rows consume the later-email quota" do
      account = account_fixture()

      for _ <- 1..30 do
        outbound_email_fixture(account,
          priority: :now,
          status: :running,
          last_attempted_at: DateTime.utc_now()
        )
      end

      pending = outbound_email_fixture(account, priority: :later, status: :pending)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: pending.id)
      assert db_entry.status == :running
      assert_email_sent()
    end

    test "stops when the per-minute rate limit is reached by :later emails" do
      account = account_fixture()

      for _ <- 1..30 do
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          last_attempted_at: DateTime.utc_now()
        )
      end

      pending = outbound_email_fixture(account, priority: :later, status: :pending)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: pending.id)
      assert db_entry.status == :pending
      refute_email_sent()
    end

    test "stops when the per-hour rate limit is reached by :later emails" do
      account = account_fixture()

      for _ <- 1..100 do
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          last_attempted_at: DateTime.utc_now() |> DateTime.add(-30, :minute)
        )
      end

      pending = outbound_email_fixture(account, priority: :later, status: :pending)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: pending.id)
      assert db_entry.status == :pending
      refute_email_sent()
    end

    test "logs a warning when the hourly rate limit is reached" do
      account = account_fixture()

      for _ <- 1..100 do
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          last_attempted_at: DateTime.utc_now() |> DateTime.add(-30, :minute)
        )
      end

      outbound_email_fixture(account, priority: :later, status: :pending)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Worker, %{})
        end)

      assert log =~ "hourly rate limit"
    end

    test "stores the ACS response id as the queue message_id" do
      account = account_fixture()
      entry = outbound_email_fixture(account, priority: :later, status: :pending)

      Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
        adapter: Swoosh.Adapters.AzureCommunicationServices,
        endpoint: "https://acs.example.com",
        auth: "acs-token"
      )

      Portal.Config.put_env_override(Portal.AzureCommunicationServices.APIClient,
        req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices.APIClient}, retry: false]
      )

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        headers = Map.new(conn.req_headers)
        refute Map.has_key?(headers, "x-ms-client-request-id")
        refute Map.has_key?(headers, "operation-id")

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-message-123", "status" => "Running"})
      end)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :running
      assert db_entry.message_id == "acs-message-123"
      assert db_entry.response["id"] == "acs-message-123"
      assert db_entry.response["status"] == "Running"
    end
  end
end
