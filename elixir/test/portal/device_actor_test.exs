defmodule Portal.DeviceActorTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.DeviceActorFixtures
  alias Portal.DeviceActor

  describe "device_actors" do
    test "one row per device and actor" do
      device_actor = device_actor_fixture()

      assert {:error, changeset} =
               %DeviceActor{}
               |> Ecto.Changeset.cast(Map.from_struct(device_actor), [
                 :account_id,
                 :device_id,
                 :actor_id,
                 :first_seen_at,
                 :last_seen_at
               ])
               |> DeviceActor.changeset()
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).account_id
    end

    test "is removed with the device" do
      account = account_fixture()
      device = client_fixture(account: account)
      device_actor = device_actor_fixture(device: device)

      Repo.delete!(device)

      refute Repo.get_by(DeviceActor,
               account_id: account.id,
               device_id: device_actor.device_id,
               actor_id: device_actor.actor_id
             )
    end

    test "is removed with the actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      device = client_fixture(account: account)
      device_actor = device_actor_fixture(device: device, actor: actor)

      Repo.delete!(actor)

      refute Repo.get_by(DeviceActor,
               account_id: account.id,
               device_id: device_actor.device_id,
               actor_id: device_actor.actor_id
             )
    end

    test "the same machine can carry several actors" do
      account = account_fixture()
      device = client_fixture(account: account)
      first = actor_fixture(account: account)
      second = actor_fixture(account: account)

      device_actor_fixture(device: device, actor: first)
      device_actor_fixture(device: device, actor: second)

      actor_ids =
        device |> Repo.preload(:device_actors) |> Map.fetch!(:device_actors) |> Enum.map(& &1.actor_id)

      assert Enum.sort(actor_ids) == Enum.sort([device.actor_id, first.id, second.id])
    end
  end
end
