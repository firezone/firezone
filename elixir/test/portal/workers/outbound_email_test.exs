defmodule Portal.Workers.OutboundEmailTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.Workers.OutboundEmail, as: Worker

  describe "perform/1" do
    test "delivers a queued job and inserts a running tracked row" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-message-123", "status" => "Running"})
      end)

      assert :ok = perform_job(Worker, queued_args(account.id))

      db_entry =
        Repo.get_by!(Portal.OutboundEmail, account_id: account.id, message_id: "acs-message-123")

      assert db_entry.status == :running
      assert db_entry.priority == :later
      assert db_entry.response["id"] == "acs-message-123"

      recipients =
        Repo.all(
          from(r in Portal.OutboundEmailRecipient,
            where: r.account_id == ^account.id,
            where: r.message_id == ^db_entry.message_id,
            order_by: [asc: r.email]
          )
        )

      assert Enum.map(recipients, &{&1.email, &1.status}) == [{"to@test.com", :pending}]
    end

    test "snoozes queued jobs when the secondary adapter is not configured" do
      account = account_fixture()

      Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
        adapter: nil,
        from_email: "test@firez.one"
      )

      assert {:snooze, 300} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
      refute_email_sent()
    end

    test "discards permanent HTTP delivery failures without tracking a row" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => %{"message" => "invalid recipient"}})
      end)

      assert {:discard, {:http_failure, 422}} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "keeps HTTP 429 delivery failures retryable" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "rate limited"}})
      end)

      assert {:error, {:http_failure, 429, %{"error" => %{"message" => "rate limited"}}}} =
               perform_job(Worker, queued_args(account.id))

      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "snoozes when the per-minute rate limit is reached" do
      account = account_fixture()

      for _ <- 1..30 do
        outbound_email_fixture(account,
          priority: :later,
          inserted_at: DateTime.utc_now() |> DateTime.add(-30, :second)
        )
      end

      log =
        capture_log(fn ->
          assert {:snooze, seconds} = perform_job(Worker, queued_args(account.id))
          assert seconds > 0
          assert seconds <= 31
        end)

      assert log =~ "rate limit reached"
      refute_email_sent()
    end

    test "snoozes when the per-hour rate limit is reached" do
      account = account_fixture()

      for _ <- 1..100 do
        outbound_email_fixture(account,
          priority: :later,
          inserted_at: DateTime.utc_now() |> DateTime.add(-30, :minute)
        )
      end

      assert {:snooze, seconds} = perform_job(Worker, queued_args(account.id))
      assert seconds > 0
      refute_email_sent()
    end

    test "does not create tracked rows for non-ACS secondary adapters" do
      account = account_fixture()

      Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
        adapter: Portal.Mailer.TestAdapter,
        from_email: "test@firez.one"
      )

      assert :ok = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
      assert_email_sent()
    end
  end

  defp queued_args(account_id) do
    %{
      "account_id" => account_id,
      "request" => %{
        "to" => [%{"name" => "", "address" => "to@test.com"}],
        "cc" => [],
        "bcc" => [],
        "from" => %{"name" => "", "address" => "from@test.com"},
        "subject" => "Test Subject",
        "html_body" => nil,
        "text_body" => "hello"
      }
    }
  end

  defp configure_acs_secondary do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      auth: "acs-token"
    )

    Portal.Config.put_env_override(Portal.AzureCommunicationServices.APIClient,
      req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices.APIClient}, retry: false]
    )
  end
end
