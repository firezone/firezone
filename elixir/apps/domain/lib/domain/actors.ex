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

  def sync_provider_groups_multi(%Auth.Provider{} = provider, attrs_list) do
    now = DateTime.utc_now()

    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    Ecto.Multi.new()
    |> Ecto.Multi.all(:groups, fn _effects_so_far ->
      Group.Query.by_account_id(provider.account_id)
      |> Group.Query.by_provider_id(provider.id)
      |> Group.Query.lock()
    end)
    |> Ecto.Multi.run(
      :plan_groups,
      fn _repo, %{groups: groups} ->
        {update, delete} =
          Enum.reduce(groups, {[], []}, fn group, {update, delete} ->
            if Map.has_key?(attrs_by_provider_identifier, group.provider_identifier) do
              {[group.provider_identifier] ++ update, delete}
            else
              {update, [group.provider_identifier] ++ delete}
            end
          end)

        insert = Map.keys(attrs_by_provider_identifier) -- (update ++ delete)

        {:ok, {update ++ insert, delete}}
      end
    )
    |> Ecto.Multi.update_all(
      :delete_groups,
      fn %{plan_groups: {_upsert, delete}} ->
        Group.Query.by_account_id(provider.account_id)
        |> Group.Query.by_provider_id(provider.id)
        |> Group.Query.by_provider_identifier({:in, delete})
      end,
      set: [deleted_at: now]
    )
    |> Ecto.Multi.run(
      :upsert_groups,
      fn repo, %{plan_groups: {upsert, _delete}} ->
        Enum.reduce_while(upsert, {:ok, []}, fn provider_identifier, {:ok, acc} ->
          attrs = Map.get(attrs_by_provider_identifier, provider_identifier)

          Group.Changeset.create_changeset(provider, attrs)
          |> repo.insert(
            conflict_target: Group.Changeset.upsert_conflict_target(),
            on_conflict: Group.Changeset.upsert_on_conflict(),
            returning: true
          )
          |> case do
            {:ok, group} ->
              {:cont, {:ok, [group | acc]}}

            {:error, changeset} ->
              {:halt, {:error, changeset}}
          end
        end)
      end
    )
  end

  def sync_provider_memberships_multi(multi, %Auth.Provider{} = provider, tuples) do
    multi
    |> Ecto.Multi.all(:memberships, fn _effects_so_far ->
      Membership.Query.by_account_id(provider.account_id)
      |> Membership.Query.by_group_provider_id(provider.id)
      |> Membership.Query.lock()
    end)
    |> Ecto.Multi.run(
      :plan_memberships,
      fn _repo,
         %{
           identities: identities,
           insert_identities: insert_identities,
           groups: groups,
           upsert_groups: upsert_groups,
           memberships: memberships
         } ->
        identity_by_provider_identifier =
          for identity <- identities ++ insert_identities, into: %{} do
            {identity.provider_identifier, identity}
          end

        group_by_provider_identifier =
          for group <- groups ++ upsert_groups, into: %{} do
            {group.provider_identifier, group}
          end

        tuples =
          Enum.map(tuples, fn {group_provider_identifier, actor_provider_identifier} ->
            {Map.fetch!(group_by_provider_identifier, group_provider_identifier).id,
             Map.fetch!(identity_by_provider_identifier, actor_provider_identifier).actor_id}
          end)

        {upsert, delete} =
          Enum.reduce(
            memberships,
            {tuples, []},
            fn membership, {upsert, delete} ->
              tuple = {membership.group_id, membership.actor_id}

              if tuple in tuples do
                {upsert -- [tuple], delete}
              else
                {upsert -- [tuple], [{membership.group_id, membership.actor_id}] ++ delete}
              end
            end
          )

        {:ok, {upsert, delete}}
      end
    )
    |> Ecto.Multi.delete_all(
      :delete_memberships,
      fn %{plan_memberships: {_upsert, delete}} ->
        Membership.Query.by_group_id_and_actor_id({:in, delete})
      end
    )
    |> Ecto.Multi.run(
      :upsert_memberships,
      fn repo, %{plan_memberships: {upsert, _delete}} ->
        Enum.reduce_while(
          upsert,
          {:ok, []},
          fn {group_id, actor_id}, {:ok, acc} ->
            attrs = %{group_id: group_id, actor_id: actor_id}

            Membership.Changeset.changeset(provider.account_id, %Membership{}, attrs)
            |> repo.insert(
              conflict_target: Membership.Changeset.upsert_conflict_target(),
              on_conflict: Membership.Changeset.upsert_on_conflict(),
              returning: true
            )
            |> case do
              {:ok, membership} ->
                {:cont, {:ok, [membership | acc]}}

              {:error, changeset} ->
                {:halt, {:error, changeset}}
            end
          end
        )
      end
    )
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      subject.account
      |> Group.Changeset.create_changeset(attrs, subject)
      |> Repo.insert()
    end
  end

  def change_group(group, attrs \\ %{})

  def change_group(%Group{provider_id: nil} = group, attrs) do
    group
    |> Repo.preload(:memberships)
    |> Group.Changeset.update_changeset(attrs)
  end

  def change_group(%Group{}, _attrs) do
    # TODO: we can change but only name
    raise ArgumentError, "can't change synced groups"
  end

  def update_group(%Group{provider_id: nil} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      group
      |> Repo.preload(:memberships)
      |> Group.Changeset.update_changeset(attrs)
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
      |> Repo.fetch_and_update(with: &Group.Changeset.delete_changeset/1)
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
    Actor.Changeset.create_changeset(attrs)
  end

  def create_actor(
        %Auth.Provider{} = provider,
        attrs,
        %Auth.Subject{} = subject
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         :ok <- Auth.ensure_has_access_to(subject, provider),
         changeset = Actor.Changeset.create_changeset(provider.account_id, attrs),
         {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate),
         :ok <- ensure_no_privilege_escalation(subject, data.type) do
      create_actor(provider, attrs)
    end
  end

  def create_actor(%Auth.Provider{} = provider, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:actor, Actor.Changeset.create_changeset(provider.account_id, attrs))
    |> Ecto.Multi.run(:identity, fn _repo, %{actor: actor} ->
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
    Actor.Changeset.update_changeset(actor, attrs)
  end

  def update_actor(%Actor{} = actor, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         changeset = Actor.Changeset.update_changeset(actor, attrs),
         {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate),
         :ok <- ensure_no_privilege_escalation(subject, data.type) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          actor = Repo.preload(actor, :memberships)
          changeset = Actor.Changeset.update_changeset(actor, attrs)

          cond do
            changeset.data.type != :admin ->
              changeset

            changeset.changes.type == :admin ->
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
          if other_enabled_admins_exist?(actor) do
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
