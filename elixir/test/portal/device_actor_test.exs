defmodule Portal.DeviceActorTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  alias Portal.DeviceActor

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor)
    now = DateTime.utc_now()

    device_actor =
      %DeviceActor{}
      |> Ecto.Changeset.change(
        account_id: account.id,
        device_id: client.id,
        actor_id: actor.id,
        first_seen_at: now,
        last_seen_at: now
      )
      |> DeviceActor.changeset()
      |> Repo.insert!()

    %{actor: actor, client: client, device_actor: device_actor}
  end

  test "an actor is recorded once per device", %{device_actor: device_actor} do
    assert {:error, changeset} =
             %DeviceActor{}
             |> Ecto.Changeset.change(Map.take(device_actor, DeviceActor.__schema__(:fields)))
             |> DeviceActor.changeset()
             |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).account_id
  end

  test "deleting the device deletes its rows", %{client: client, device_actor: device_actor} do
    Repo.delete!(client)

    refute Repo.get_by(DeviceActor, Map.take(device_actor, [:account_id, :device_id, :actor_id]))
  end

  test "deleting the actor deletes its rows", %{actor: actor, device_actor: device_actor} do
    Repo.delete!(actor)

    refute Repo.get_by(DeviceActor, Map.take(device_actor, [:account_id, :device_id, :actor_id]))
  end
end
