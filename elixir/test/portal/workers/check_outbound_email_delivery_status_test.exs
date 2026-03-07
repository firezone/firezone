defmodule Portal.Workers.CheckOutboundEmailDeliveryStatusTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.Workers.CheckOutboundEmailDeliveryStatus, as: Worker

  setup do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      auth: "acs-token"
    )

    Portal.Config.put_env_override(Portal.AzureCommunicationServices.APIClient,
      req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices.APIClient}, retry: false]
    )

    :ok
  end

  describe "perform/1" do
    test "keeps running entries inflight while the ACS operation is still running" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "op-123"
        )

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/emails/operations/op-123"
        Req.Test.json(conn, %{"id" => "op-123", "status" => "Running"})
      end)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :running
      assert db_entry.response["operation"]["status"] == "Running"
    end

    test "marks running entries succeeded when the ACS operation succeeds" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "op-456"
        )

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.request_path == "/emails/operations/op-456"
        Req.Test.json(conn, %{"id" => "op-456", "status" => "Succeeded"})
      end)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :succeeded
      assert is_nil(db_entry.failed_at)
      assert db_entry.response["delivery_state"] == "Succeeded"
    end

    test "marks running entries failed without inferring recipient deliverability when ACS reports failure" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "op-789"
        )

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.request_path == "/emails/operations/op-789"

        Req.Test.json(conn, %{
          "id" => "op-789",
          "status" => "Failed",
          "error" => %{
            "code" => "EmailDropped",
            "message" => "Email was dropped after several attempts to deliver."
          }
        })
      end)

      assert :ok = perform_job(Worker, %{})

      db_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert db_entry.status == :failed
      assert db_entry.failed_at != nil
      assert db_entry.response["operation"]["error"]["code"] == "EmailDropped"
      assert Repo.aggregate(Portal.EmailSuppression, :count, :email) == 0
    end

    test "does not mutate recipient deliverability from message-level poll results" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "op-101"
        )

      Repo.insert!(%Portal.OutboundEmailRecipient{
        account_id: account.id,
        outbound_email_id: entry.id,
        kind: :to,
        email: "to@test.com",
        status: :pending
      })

      Req.Test.stub(Portal.AzureCommunicationServices.APIClient, fn conn ->
        assert conn.request_path == "/emails/operations/op-101"
        Req.Test.json(conn, %{"id" => "op-101", "status" => "Succeeded"})
      end)

      assert :ok = perform_job(Worker, %{})

      recipient =
        Repo.get_by!(Portal.OutboundEmailRecipient,
          outbound_email_id: entry.id,
          email: "to@test.com"
        )

      assert recipient.status == :pending
      assert is_nil(recipient.last_event_at)
    end
  end
end
