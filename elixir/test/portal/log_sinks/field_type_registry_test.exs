defmodule Portal.LogSinks.FieldTypeRegistryTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ChangeLogFixtures
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

  test "nested payload fields register under their producer", %{account: account} do
    sink = splunk_log_sink_fixture(account: account, enabled_streams: [:change])
    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

    change_log_fixture(
      account: account,
      object: "resources",
      operation: :update,
      before: %{"name" => "old", "port" => 443},
      after: %{"name" => "new", "port" => 443, "config" => %{"deep" => true, "tags" => ["a"]}}
    )

    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

    registered =
      from(t in FieldType, where: like(t.name, "change.resources.%"))
      |> Repo.all()
      |> Map.new(&{&1.name, &1.type})

    # before and after mirror the same table schema, so they share a namespace.
    assert registered == %{
             "change.resources.name" => "string",
             "change.resources.port" => "integer",
             "change.resources.config" => "object",
             "change.resources.config.deep" => "boolean",
             "change.resources.config.tags" => "array"
           }
  end

  test "a column changing type in a migration pages us", %{account: account} do
    Repo.insert_all(FieldType, [
      %{name: "change.resources.port", type: "string", inserted_at: DateTime.utc_now()}
    ])

    sink = splunk_log_sink_fixture(account: account, enabled_streams: [:change])
    assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})

    change_log_fixture(
      account: account,
      object: "resources",
      operation: :update,
      before: %{"port" => 443},
      after: %{"port" => 443}
    )

    log_output =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = perform_job(Splunk.Sync, %{log_sink_id: sink.id})
      end)

    assert log_output =~ "Log sink field type divergence"
    assert log_output =~ "change.resources.port"
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
