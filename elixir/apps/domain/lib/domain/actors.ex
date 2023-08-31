defmodule Domain.Actors do
  alias Domain.Actors.Membership
  alias Web.Devices
  alias Domain.{Repo, Validator}
  alias Domain.{Auth, Devices}
  alias Domain.Actors.{Authorizer, Actor, Group}
  require Ecto.Query

  # Groups

  def fetch_groups_count_grouped_by_provider_id(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {:ok, groups} =
        Group.Query.group_by_provider_id()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      groups =
        Enum.reduce(groups, %{}, fn %{provider_id: id, count: count}, acc ->
          Map.put(acc, id, count)
        end)

      {:ok, groups}
    end
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, group} -> {:ok, Repo.preload(group, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, groups} =
        Group.Query.all()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(groups, preload)}
    end
  end

  def peek_group_actors(groups, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      ids = groups |> Enum.map(& &1.id) |> Enum.uniq()
      preview = Map.new(ids, fn id -> {id, %{count: 0, actors: []}} end)

      preview =
        Group.Query.by_id({:in, ids})
        |> Group.Query.preload_few_actors_for_each_group(limit)
        |> Repo.all()
        |> Enum.group_by(&{&1.group_id, &1.count}, & &1.actor)
        |> Enum.reduce(preview, fn {{group_id, count}, actors}, acc ->
          Map.put(acc, group_id, %{count: count, actors: actors})
        end)

      {:ok, preview}
    end
  end

  def sync_provider_groups_multi(%Auth.Provider{} = provider, attrs_list) do
    Group.Sync.sync_provider_groups_multi(provider, attrs_list)
  end

  def sync_provider_memberships_multi(multi, %Auth.Provider{} = provider, tuples) do
    Membership.Sync.sync_provider_memberships_multi(multi, provider, tuples)
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      subject.account
      |> Group.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def change_group(group, attrs \\ %{})

  def change_group(%Group{provider_id: nil} = group, attrs) do
    group
    |> Repo.preload(:memberships)
    |> Group.Changeset.update(attrs)
  end

  def change_group(%Group{}, _attrs) do
    raise ArgumentError, "can't change synced groups"
  end

  def update_group(%Group{provider_id: nil} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      group
      |> Repo.preload(:memberships)
      |> Group.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_group(%Group{}, _attrs, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def delete_group(%Group{provider_id: nil} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Group.Query.by_account_id(subject.account.id)
      |> Repo.fetch_and_update(with: &Group.Changeset.delete/1)
    end
  end

  def delete_group(%Group{}, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def group_synced?(%Group{provider_id: nil}), do: false
  def group_synced?(%Group{}), do: true

  def group_deleted?(%Group{deleted_at: nil}), do: false
  def group_deleted?(%Group{}), do: true

  # Actors

  def fetch_actors_count_by_type(type, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_type(type)
      |> Authorizer.for_subject(subject)
      |> Repo.aggregate(:count)
    end
  end

  def fetch_actor_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Actor.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, actor} -> {:ok, Repo.preload(actor, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_actor_by_id(id) do
    if Validator.valid_uuid?(id) do
      Actor.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_actor_by_id!(id) do
    Actor.Query.by_id(id)
    |> Repo.fetch!()
  end

  def list_actors(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {:ok, actors} =
        Actor.Query.all()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(actors, preload)}
    end
  end

  def new_actor(attrs \\ %{memberships: []}) do
    Actor.Changeset.create(attrs)
  end

  def create_actor(
        %Auth.Provider{} = provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         :ok <- Auth.ensure_has_access_to(subject, provider),
         changeset = Actor.Changeset.create(provider.account_id, attrs),
         {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate),
         :ok <- ensure_no_privilege_escalation(subject, data.type) do
      create_actor(provider, attrs)
    end
  end

  def create_actor(%Auth.Provider{} = provider, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:actor, Actor.Changeset.create(provider.account_id, attrs))
    |> Ecto.Multi.run(:identity, fn _repo, %{actor: actor} ->
      # TODO: we should not reuse the same attrs here, instead we should use attrs["identities"] list for that,
      # this will make LV forms more consistent and remove some hacks
      Auth.create_identity(actor, provider, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{actor: actor, identity: identity}} ->
        {:ok, %{actor | identities: [identity]}}

      {:error, _step, changeset, _effects_so_far} ->
        {:error, changeset}
    end
  end

  def change_actor(%Actor{} = actor, attrs \\ %{}) do
    Actor.Changeset.update(actor, attrs)
  end

  def update_actor(%Actor{} = actor, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         changeset = Actor.Changeset.update(actor, attrs),
         {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate),
         :ok <- ensure_no_privilege_escalation(subject, data.type) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          actor = Repo.preload(actor, :memberships)
          changeset = Actor.Changeset.update(actor, attrs)

          cond do
            changeset.data.type != :account_admin_user ->
              changeset

            Map.get(changeset.changes, :type) == :account_admin_user ->
              changeset

            other_enabled_admins_exist?(actor) ->
              changeset

            true ->
              :cant_remove_admin_type
          end
        end
      )
    end
  end

  def disable_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          if actor.type != :account_admin_user or other_enabled_admins_exist?(actor) do
            Actor.Changeset.disable_actor(actor)
          else
            :cant_disable_the_last_admin
          end
        end
      )
    end
  end

  def enable_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Actor.Changeset.enable_actor/1)
    end
  end

  def delete_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          if actor.type != :account_admin_user or other_enabled_admins_exist?(actor) do
            :ok = Auth.delete_actor_identities(actor)
            :ok = Devices.delete_actor_devices(actor)

            Actor.Changeset.delete_actor(actor)
          else
            :cant_delete_the_last_admin
          end
        end
      )
    end
  end

  # TODO: when actor is synced we should not allow changing the name
  def actor_synced?(%Actor{last_synced_at: nil}), do: false
  def actor_synced?(%Actor{}), do: true

  def actor_deleted?(%Actor{deleted_at: nil}), do: false
  def actor_deleted?(%Actor{}), do: true

  def actor_disabled?(%Actor{disabled_at: nil}), do: false
  def actor_disabled?(%Actor{}), do: true

  defp ensure_no_privilege_escalation(subject, granted_actor_type) do
    granted_permissions = Auth.fetch_type_permissions!(granted_actor_type)

    if MapSet.subset?(granted_permissions, subject.permissions) do
      :ok
    else
      missing_permissions =
        MapSet.difference(granted_permissions, subject.permissions)
        |> MapSet.to_list()

      {:error, {:unauthorized, privilege_escalation: missing_permissions}}
    end
  end

  defp other_enabled_admins_exist?(%Actor{
         type: :account_admin_user,
         account_id: account_id,
         id: id
       }) do
    Actor.Query.by_type(:account_admin_user)
    |> Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account_id)
    |> Actor.Query.by_id({:not, id})
    |> Actor.Query.lock()
    |> Repo.exists?()
  end

  defp other_enabled_admins_exist?(%Actor{}) do
    false
  end
end
