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

    test "discards HTTP delivery failures without tracking a row" do
      account = account_fixture()
      configure_acs_secondary()

      Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/emails:send"

        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => %{"message" => "invalid recipient"}})
      end)

      assert {:discard, {422, _body}} = perform_job(Worker, queued_args(account.id))
      assert Repo.aggregate(Portal.OutboundEmail, :count, :message_id) == 0
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
      auth: "acs-token",
      req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices}, retry: false]
    )
  end
end
