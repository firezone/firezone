defmodule Portal.DeviceActorFixtures do
  @moduledoc """
  Test helpers for recording that an actor has connected on a device.
  """

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures

  @doc """
  Generate a device_actors row. The device, actor, and account are created
  unless provided; `first_seen_at` and `last_seen_at` default to now.

  ## Examples

      device_actor = device_actor_fixture()
      device_actor = device_actor_fixture(device: device, actor: actor)
      device_actor = device_actor_fixture(device: device, last_seen_at: a_week_ago)

  """
  def device_actor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account =
      cond do
        device = Map.get(attrs, :device) ->
          Portal.Repo.preload(device, :account).account

        actor = Map.get(attrs, :actor) ->
          Portal.Repo.preload(actor, :account).account

        true ->
          Map.get(attrs, :account) || account_fixture()
      end

    actor = Map.get(attrs, :actor) || actor_fixture(account: account)
    device = Map.get(attrs, :device) || client_fixture(account: account, actor: actor)

    now = DateTime.utc_now()

    device_actor_attrs =
      attrs
      |> Map.drop([:account, :actor, :device])
      |> Map.put(:account_id, account.id)
      |> Map.put(:device_id, device.id)
      |> Map.put(:actor_id, actor.id)
      |> Map.put_new(:first_seen_at, now)
      |> Map.put_new(:last_seen_at, now)

    # The client fixture already records its own actor, so a pair that exists
    # is widened to the given window rather than inserted again.
    first_seen_at = device_actor_attrs.first_seen_at
    last_seen_at = device_actor_attrs.last_seen_at

    widen =
      from(da in Portal.DeviceActor,
        update: [
          set: [
            first_seen_at: fragment("LEAST(?, ?)", da.first_seen_at, ^first_seen_at),
            last_seen_at: fragment("GREATEST(?, ?)", da.last_seen_at, ^last_seen_at)
          ]
        ]
      )

    {:ok, device_actor} =
      %Portal.DeviceActor{}
      |> Ecto.Changeset.cast(device_actor_attrs, [
        :account_id,
        :device_id,
        :actor_id,
        :first_seen_at,
        :last_seen_at
      ])
      |> Portal.DeviceActor.changeset()
      |> Portal.Repo.insert(
        on_conflict: widen,
        conflict_target: [:account_id, :device_id, :actor_id]
      )

    Portal.Repo.get_by!(Portal.DeviceActor,
      account_id: device_actor.account_id,
      device_id: device_actor.device_id,
      actor_id: device_actor.actor_id
    )
  end
end
