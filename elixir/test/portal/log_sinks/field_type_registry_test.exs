defmodule Portal.LogSinks.FieldTypeRegistryTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.FlowLogFixtures
  import Portal.LogSinkFixtures
  import Portal.SessionLogFixtures

  alias Portal.LogSinks.FieldType
  alias Portal.Splunk

  setup do
    Req.Test.stub(Splunk.APIClient, fn conn ->
      Req.Test.json(conn, %{"text" => "Success", "code" => 0})
    end)

    %{account: account_fixture()}
  end

  test "delivery re-registers unseeded fields with the seeded types", %{account: account} do
    # Remove a few seeded rows so this delivery has to register them, proving
    # the observed wire types agree with what the migration seeded.
    from(t in FieldType, where: t.name in ["context", "rx_bytes", "subject"])
    |> Repo.delete_all()

    sink = splunk_log_sink_fixture(account: account, enabled_streams: [:session, :flow])
    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

    session_log_fixture(account: account)
    flow_log_fixture(account: account, domain: "example.com")

    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

    registered =
      from(t in FieldType, where: t.name in ["context", "rx_bytes", "subject"])
      |> Repo.all()
      |> Map.new(&{&1.name, &1.type})

    assert registered == %{"context" => "string", "rx_bytes" => "integer", "subject" => "object"}
  end

  test "a type change against the registered contract pages us", %{account: account} do
    from(t in FieldType, where: t.name == "log_id")
    |> Repo.update_all(set: [type: "integer"])

    sink = splunk_log_sink_fixture(account: account, enabled_streams: [:session])
    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
    session_log_fixture(account: account)

    log_output =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      end)

    assert log_output =~ "Log sink field type divergence"
    assert log_output =~ "log_id"

    # Detection only: delivery is not blocked and the sink's customer-facing
    # state is untouched.
    sink = Repo.get_by!(Splunk.LogSink, account_id: sink.account_id, id: sink.id)
    refute sink.errored_at
    refute sink.is_disabled
  end
end
