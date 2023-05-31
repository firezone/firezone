defmodule Domain.Devices.Device.Query do
  use Domain, :query

  def all do
    from(devices in Domain.Devices.Device, as: :devices)
    |> where([devices: devices], is_nil(devices.deleted_at))
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [devices: devices], devices.id == ^id)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    where(queryable, [devices: devices], devices.actor_id == ^actor_id)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [devices: devices], devices.account_id == ^account_id)
  end

  def returning_all(queryable \\ all()) do
    select(queryable, [devices: devices], devices)
  end

  def with_preloaded_actor(queryable \\ all()) do
    with_named_binding(queryable, :actor, fn queryable, binding ->
      queryable
      |> join(:inner, [devices: devices], actor in assoc(devices, ^binding), as: ^binding)
      |> preload([devices: devices, actor: actor], actor: actor)
    end)
  end

  def with_preloaded_identity(queryable \\ all()) do
    with_named_binding(queryable, :identity, fn queryable, binding ->
      queryable
      |> join(:inner, [devices: devices], identity in assoc(devices, ^binding), as: ^binding)
      |> preload([devices: devices, identity: identity], identity: identity)
    end)
  end
end
