defmodule Portal.Workers.SyncStripeCustomerTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import ExUnit.CaptureLog
  import Portal.AccountFixtures

  alias Portal.Workers.SyncStripeCustomer

  test "sends the account to Stripe" do
    account = account_fixture(metadata: %{stripe: %{customer_id: "cus_sync_test"}})
    test_pid = self()

    Req.Test.stub(Portal.Billing.Stripe.APIClient, fn conn ->
      send(test_pid, {:customer_update, conn.request_path})
      Req.Test.json(conn, %{"id" => "cus_sync_test"})
    end)

    assert :ok = perform_job(SyncStripeCustomer, %{"account_id" => account.id})
    assert_received {:customer_update, "/v1/customers/cus_sync_test"}
  end

  test "fails so Oban retries when Stripe fails" do
    account = account_fixture(metadata: %{stripe: %{customer_id: "cus_sync_test"}})
    Req.Test.stub(Portal.Billing.Stripe.APIClient, fn conn -> Plug.Conn.send_resp(conn, 503, "{}") end)

    capture_log(fn ->
      assert {:error, :retry_later} = perform_job(SyncStripeCustomer, %{"account_id" => account.id})
    end)
  end

  test "merges a new change into a job that has not run yet" do
    account_id = Ecto.UUID.generate()

    assert {:ok, first} = %{account_id: account_id} |> SyncStripeCustomer.new() |> Oban.insert()
    assert {:ok, second} = %{account_id: account_id} |> SyncStripeCustomer.new() |> Oban.insert()

    assert second.conflict?
    assert second.id == first.id
  end
end
