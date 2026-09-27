defmodule Portal.LogPartitionMirrorsTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.SessionLogFixtures
  import Portal.APIRequestLogFixtures
  import Portal.ChangeLogFixtures

  alias Portal.{APIRequestLog, ChangeLog, SessionLog}
  alias Portal.ChangeLogs.Consumer.Database, as: Consumer
  alias Portal.Types.LogId

  test "mirrors each stream with exactly the stored payload and sequence" do
    for {schema, log} <- [
          {SessionLog, session_log_fixture()},
          {APIRequestLog, api_request_log_fixture()},
          {ChangeLog, change_log_fixture()}
        ] do
      assert mirror(schema, log) == Ecto.reset_fields(log, [:account])
    end
  end

  test "MCP updates keep the original identity and update the mirror" do
    log = api_request_log_fixture(mcp: %{"outcome" => "received"})

    {:ok, updated} =
      PortalAPI.Plugs.RequestLog.Database.update_mcp(log, %{
        "tool_name" => "list_resources",
        "outcome" => "succeeded",
        "rest_status" => 200
      })

    assert updated.seq == log.seq
    assert updated.inserted_at == log.inserted_at
    assert mirror(APIRequestLog, updated) == Ecto.reset_fields(updated, [:account])
    assert APIRequestLog.__schema__(:primary_key) == [:account_id, :log_id, :inserted_at]
  end

  test "MCP updates include the partition timestamp in SQL" do
    log = api_request_log_fixture()
    id = make_ref()
    owner = self()

    :telemetry.attach(id, [:portal, :repo, :query], fn _event, _measurements, metadata, _ ->
      if self() == owner, do: send(owner, {:query, metadata.query})
    end, nil)

    try do
      {:ok, _} = PortalAPI.Plugs.RequestLog.Database.update_mcp(log, %{"outcome" => "dispatched"})
      assert_receive {:query, query}
      assert query =~ ~s(UPDATE "api_request_logs")
      [_set, where] = String.split(query, " WHERE ")
      assert where =~ ~s("inserted_at")
    after
      :telemetry.detach(id)
    end
  end

  test "updating a pre-activation MCP request seeds its mirror in the original day's partition" do
    yesterday = DateTime.new!(Date.add(Date.utc_today(), -1), ~T[23:59:59.000000], "Etc/UTC")
    log = api_request_log_fixture(inserted_at: yesterday, mcp: %{"outcome" => "received"})

    Repo.delete_all(from l in {"api_request_logs_partitioned", APIRequestLog}, where: l.account_id == ^log.account_id)

    {:ok, updated} = PortalAPI.Plugs.RequestLog.Database.update_mcp(log, %{"outcome" => "succeeded"})
    assert mirror(APIRequestLog, updated) == Ecto.reset_fields(updated, [:account])
    assert updated.inserted_at == yesterday
  end

  test "a replay with a new public ID creates no second mirror row" do
    account = account_fixture()
    original = change_log_fixture(account: account)

    replay =
      original
      |> Map.from_struct()
      |> Map.take(ChangeLog.__schema__(:fields))
      |> Map.drop([:seq])
      |> Map.put(:log_id, LogId.build_change_log(System.os_time(:microsecond), 2))

    assert Consumer.bulk_insert([replay]) == 0
    assert mirror(ChangeLog, original) == original

    # Verify the replacement's conflict target independently of legacy LSN
    # deduplication. The WAL timestamp stays stable across consumer restarts.
    assert {0, []} =
             Repo.insert_all({"change_logs_partitioned", ChangeLog}, [replay],
               on_conflict: :nothing,
               conflict_target: [:timestamp, :lsn],
               returning: true
             )
  end

  test "rolling back a source write also rolls back the mirror" do
    account = account_fixture()

    assert {:error, log_id} =
             Repo.transaction(fn ->
               log = session_log_fixture(account: account)
               assert mirror(SessionLog, log) == log
               Repo.rollback(log.log_id)
             end)

    refute Repo.one(from l in SessionLog, where: l.log_id == ^log_id)
    refute Repo.one(from l in {"session_logs_partitioned", SessionLog}, where: l.log_id == ^log_id)
  end

  test "individual deletes and account cascades remove mirrors" do
    account = account_fixture()
    session = session_log_fixture(account: account)
    request = api_request_log_fixture(account: account)
    change = change_log_fixture(account: account)

    Repo.delete!(request)
    refute mirror(APIRequestLog, request)

    Repo.delete!(account)
    refute mirror(SessionLog, session)
    refute mirror(ChangeLog, change)
  end

  test "expired writes remain supported on the legacy table without recreating old partitions" do
    log = session_log_fixture(timestamp: DateTime.add(DateTime.utc_now(), -100, :day))
    assert Repo.get_by!(SessionLog, log_id: log.log_id)
    refute mirror(SessionLog, log)
  end

  test "the retained boundary day is UTC regardless of the connection timezone" do
    Repo.query!("SET LOCAL timezone = 'Pacific/Honolulu'")
    boundary = DateTime.new!(Date.add(Date.utc_today(), -90), ~T[00:00:00.000000], "Etc/UTC")
    retained = session_log_fixture(timestamp: boundary)
    expired = session_log_fixture(timestamp: DateTime.add(boundary, -1, :second))

    assert mirror(SessionLog, retained) == retained
    refute mirror(SessionLog, expired)
  end

  test "a failed mirror insert fails the source insert too" do
    account = account_fixture()
    id = LogId.build_session_log()

    # Beyond the pre-created future buffer, there is deliberately no default
    # partition to hide a stopped maintainer or a badly skewed clock.
    assert_raise Postgrex.Error, ~r/no partition of relation/, fn ->
      Repo.insert_all(SessionLog, [%{
        account_id: account.id,
        log_id: id,
        timestamp: DateTime.add(DateTime.utc_now(), 30, :day),
        context: :client,
        subject: %{}
      }], mode: :savepoint)
    end

    refute Repo.get_by(SessionLog, log_id: id)
  end

  defp mirror(schema, log) do
    source = schema.__schema__(:source) <> "_partitioned"
    result = Repo.one(from l in {source, schema}, where: l.account_id == ^log.account_id and l.log_id == ^log.log_id)

    # Only the source name in Ecto metadata differs.
    if result, do: Ecto.put_meta(result, source: schema.__schema__(:source))
  end
end
