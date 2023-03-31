defmodule Domain.Devices do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  alias Domain.Actors
  alias Domain.Devices.{Device, Authorizer, Presence}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def count_by_account_id(account_id) do
    Device.Query.by_account_id(account_id)
    |> Repo.aggregate(:count)
  end

  def count_by_actor_id(actor_id) do
    Device.Query.by_actor_id(actor_id)
    |> Repo.aggregate(:count)
  end

  def fetch_device_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.manage_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Device.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_device_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Device.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
  end

  def list_devices(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.manage_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Device.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_devices_for_actor(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    list_devices_by_actor_id(actor.id, subject)
  end

  def list_devices_by_actor_id(actor_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.manage_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(actor_id) do
      Device.Query.by_actor_id(actor_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.Changeset.update_changeset(device, attrs)
  end

  def upsert_device(attrs \\ %{}, %Auth.Subject{identity: %Auth.Identity{} = identity} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_devices_permission()) do
      changeset = Device.Changeset.upsert_changeset(identity, subject.context, attrs)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:device, changeset,
        conflict_target: Device.Changeset.upsert_conflict_target(),
        on_conflict: Device.Changeset.upsert_on_conflict(),
        returning: true
      )
      |> resolve_address_multi(:ipv4)
      |> resolve_address_multi(:ipv6)
      |> Ecto.Multi.update(:device_with_address, fn
        %{device: %Device{} = device, ipv4: ipv4, ipv6: ipv6} ->
          Device.Changeset.finalize_upsert_changeset(device, ipv4, ipv6)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{device_with_address: device}} -> {:ok, device}
        {:error, :device, changeset, _effects_so_far} -> {:error, changeset}
      end
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{device: %Device{} = device} ->
      if address = Map.get(device, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(device.account_id, type)}
      end
    end)
  end

  def update_device(%Device{} = device, attrs, %Auth.Subject{} = subject) do
    with :ok <- authorize_actor_device_management(device.actor_id, subject) do
      Device.Query.by_id(device.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Device.Changeset.update_changeset(&1, attrs))
    end
  end

  def delete_device(%Device{} = device, %Auth.Subject{} = subject) do
    with :ok <- authorize_actor_device_management(device.actor_id, subject) do
      Device.Query.by_id(device.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Device.Changeset.delete_changeset/1)
    end
  end

  def authorize_actor_device_management(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    authorize_actor_device_management(actor.id, subject)
  end

  def authorize_actor_device_management(actor_id, %Auth.Subject{actor: %{id: actor_id}} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_own_devices_permission())
  end

  def authorize_actor_device_management(_actor_id, %Auth.Subject{} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_devices_permission())
  end

  def connect_device(%Device{} = device) do
    # TODO: use new Phoenix.Tracker instead
    Phoenix.PubSub.subscribe(Domain.PubSub, "actor:#{device.actor_id}")

    {:ok, _} =
      Presence.track(self(), "devices:#{device.account_id}", device.id, %{
        online_at: System.system_time(:second)
      })

    :ok
  end

  def fetch_device_config!(%Device{} = device) do
    %{
      devices_upstream_dns: upstream_dns
    } = Domain.Config.fetch_resolved_configs!(device.account_id, [:devices_upstream_dns])

    [upstream_dns: upstream_dns]
  end
end
