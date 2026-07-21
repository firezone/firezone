defmodule Portal.Workers.OutboundEmailTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Workers.OutboundEmail, as: Worker

  describe "perform/1" do
    test "delivers a queued job and inserts a running tracked row" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-message-123", "status" => "Running"})
      end)

      assert :ok = perform_job(Worker, queued_args(account.id))

      db_entry =
        Repo.get_by!(Portal.OutboundEmail, account_id: account.id, message_id: "acs-message-123")

      assert db_entry.subject == "Test Subject"
      assert db_entry.recipients == ["to@test.com"]
    end

    test "skips delivery when the recipient was suppressed after enqueue" do
      account = account_fixture()
      configure_acs_secondary()
      test_pid = self()

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email("to@test.com")
      })

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        send(test_pid, :acs_request_sent)

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-should-not-send", "status" => "Running"})
      end)

      assert :ok = perform_job(Worker, queued_args(account.id))

      refute_received :acs_request_sent
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "returns error on HTTP delivery failures without tracking a row" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => %{"message" => "invalid recipient"}})
      end)

      assert {:error, {422, _body}} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "returns error for 401 so Oban retries" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "Unauthorized"}})
      end)

      assert {:error, {401, _body}} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "returns error for 403 so Oban retries" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"message" => "Forbidden"}})
      end)

      assert {:error, {403, _body}} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
    end

    test "respects ACS 429 retry-after with a fresh HMAC signature" do
      account = account_fixture()

      Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
        adapter: Swoosh.Adapters.AzureCommunicationServices,
        endpoint: "https://acs.example.com",
        access_key: Base.encode64("acs-secret"),
        req_opts: [
          plug: {Req.Test, Portal.AzureCommunicationServices},
          retry: :transient,
          max_retries: 1
        ]
      )

      test_pid = self()
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
            |> Req.Test.json(%{"id" => "acs-message-429", "status" => "Running"})
        end
      end)

      assert :ok = perform_job(Worker, queued_args(account.id))
      assert_received {:acs_attempt, 0, first_headers}
      assert_received {:acs_attempt, 1, second_headers}
      assert first_headers.x_ms_date != second_headers.x_ms_date
      assert first_headers.authorization != second_headers.authorization

      db_entry =
        Repo.get_by!(Portal.OutboundEmail, account_id: account.id, message_id: "acs-message-429")

      assert db_entry.subject == "Test Subject"
    end

    test "sets deterministic Operation-Id header derived from job id" do
      account = account_fixture()
      configure_acs_secondary()

      test_pid = self()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        operation_id =
          Enum.find_value(conn.req_headers, fn
            {"operation-id", value} -> value
            _ -> nil
          end)

        send(test_pid, {:operation_id, operation_id})

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"id" => "acs-msg-opid", "status" => "Running"})
      end)

      job = %Oban.Job{id: 42, args: queued_args(account.id)}
      assert :ok = Worker.perform(job)

      assert_received {:operation_id, "00000000-0000-0000-0000-00000000002a"}
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

  defp configure_acs_secondary(req_opts \\ [
         plug: {Req.Test, Portal.AzureCommunicationServices},
         retry: false
       ]) do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      auth: "acs-token",
      req_opts: req_opts
    )
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
