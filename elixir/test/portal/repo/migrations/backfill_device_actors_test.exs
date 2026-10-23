defmodule Portal.Repo.Migrations.BackfillDeviceActorsTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.DeviceActorFixtures
  alias Portal.DeviceActor

  Code.require_file("priv/repo/migrations/20261022120011_backfill_device_actors.exs")
  alias Portal.Repo.Migrations.BackfillDeviceActors

  setup do
    account = account_fixture()
    %{account: account}
  end

  defp backfill do
    Repo.query!(BackfillDeviceActors.backfill_statement())
  end

  defp device_actor(device, actor) do
    Repo.get_by(DeviceActor,
      account_id: device.account_id,
      device_id: device.id,
      actor_id: actor.id
    )
  end

  test "copies the owner of every client device", %{account: account} do
    actor = actor_fixture(account: account)
    last_seen_at = DateTime.utc_now() |> DateTime.add(-3, :day)
    client = client_fixture(account: account, actor: actor) |> record_last_seen(last_seen_at)

    backfill()

    row = device_actor(client, actor)
    assert DateTime.compare(row.first_seen_at, client.inserted_at) == :eq
    assert DateTime.compare(row.last_seen_at, last_seen_at) == :eq
  end

  test "a device that never connected is first and last seen when it was created", %{
    account: account
  } do
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor) |> record_last_seen(nil)

    backfill()

    row = device_actor(client, actor)
    assert DateTime.compare(row.first_seen_at, client.inserted_at) == :eq
    assert DateTime.compare(row.last_seen_at, client.inserted_at) == :eq
  end

  test "skips gateways", %{account: account} do
    gateway_fixture(account: account)

    backfill()

    assert Repo.aggregate(DeviceActor, :count) == 0
  end

  test "keeps the wider window of a row a connect already wrote", %{account: account} do
    actor = actor_fixture(account: account)
    now = DateTime.utc_now()
    client = client_fixture(account: account, actor: actor) |> record_last_seen(now)
    earlier = DateTime.add(client.inserted_at, -1, :day)
    later = DateTime.add(now, 1, :day)

    device_actor_fixture(device: client, actor: actor, first_seen_at: earlier, last_seen_at: later)

    backfill()

    row = device_actor(client, actor)
    assert DateTime.compare(row.first_seen_at, earlier) == :eq
    assert DateTime.compare(row.last_seen_at, later) == :eq
  end

  test "runs again without duplicating rows", %{account: account} do
    actor = actor_fixture(account: account)
    client_fixture(account: account, actor: actor)

    backfill()
    backfill()

    assert Repo.aggregate(DeviceActor, :count) == 1
  end
end
