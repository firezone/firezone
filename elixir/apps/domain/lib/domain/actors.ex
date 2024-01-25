defmodule Domain.Actors do
  alias Domain.Actors.Membership
  alias Web.Clients
  alias Domain.{Repo, Validator}
  alias Domain.{Accounts, Auth, Tokens, Clients, Policies}
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

      Group.Query.all()
      |> Group.Query.by_id(id)
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
        Group.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(groups, preload)}
    end
  end

  def peek_group_actors(groups, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      ids = groups |> Enum.map(& &1.id) |> Enum.uniq()

      Group.Query.by_id({:in, ids})
      |> Group.Query.preload_few_actors_for_each_group(limit)
      |> Authorizer.for_subject(subject)
      |> Repo.peek(groups)
    end
  end

  def peek_actor_groups(actors, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      ids = actors |> Enum.map(& &1.id) |> Enum.uniq()

      Actor.Query.by_id({:in, ids})
      |> Actor.Query.preload_few_groups_for_each_actor(limit)
      |> Authorizer.for_subject(subject)
      |> Repo.peek(actors)
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
    Group.Changeset.update(group, attrs)
  end

  def change_group(%Group{}, _attrs) do
    raise ArgumentError, "can't change synced groups"
  end

  def update_group(%Group{provider_id: nil} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      group
      |> Group.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def update_group(%Group{}, _attrs, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def delete_group(%Group{provider_id: nil} = group, %Auth.Subject{} = subject) do
    queryable = Group.Query.by_id(group.id)

    case delete_groups(queryable, subject) do
      {:ok, [group]} ->
        {:ok, _policies} = Policies.delete_policies_for(group, subject)

        {_count, nil} =
          Membership.Query.by_group_id(group.id)
          |> Repo.delete_all()

        {:ok, group}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_group(%Group{}, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def delete_groups_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    queryable =
      Group.Query.by_provider_id(provider.id)
      |> Group.Query.by_account_id(provider.account_id)

    {_count, nil} =
      Membership.Query.by_group_provider_id(provider.id)
      |> Repo.delete_all()

    with {:ok, groups} <- delete_groups(queryable, subject) do
      {:ok, _policies} = Policies.delete_policies_for(provider, subject)
      {:ok, groups}
    end
  end

  defp delete_groups(queryable, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {_count, groups} =
        queryable
        |> Authorizer.for_subject(subject)
        |> Group.Query.delete()
        |> Repo.update_all([])

      {:ok, groups}
    end
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

      Actor.Query.all()
      |> Actor.Query.by_id(id)
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

  # TODO: this should be replaced with list_groups(..., filter: %{actor_id: actor.id})
  def list_actor_group_ids(%Actor{} = actor) do
    actor = Repo.preload(actor, :memberships)

    group_ids =
      actor.memberships
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()

    {:ok, group_ids}
  end

  def list_actors(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {:ok, actors} =
        Actor.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(actors, preload)}
    end
  end

  def new_actor(attrs \\ %{memberships: []}) do
    Actor.Changeset.create(attrs)
  end

  def create_actor(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account) do
      Actor.Changeset.create(account.id, attrs, subject)
      |> Repo.insert()
    end
  end

  def create_actor(%Accounts.Account{} = account, attrs) do
    Actor.Changeset.create(account.id, attrs)
    |> Repo.insert()
  end

  def change_actor(%Actor{} = actor, attrs \\ %{}) do
    Actor.Changeset.update(actor, [], attrs)
  end

  def update_actor(%Actor{} = actor, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          actor = maybe_preload_not_synced_memberships(actor, attrs)
          blacklisted_groups = list_blacklisted_groups(attrs)
          changeset = Actor.Changeset.update(actor, attrs, blacklisted_groups, subject)

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

  defp maybe_preload_not_synced_memberships(actor, attrs) do
    if Map.has_key?(attrs, "memberships") || Map.has_key?(attrs, :memberships) do
      memberships =
        Membership.Query.by_actor_id(actor.id)
        |> Membership.Query.by_not_synced_group()
        |> Membership.Query.lock()
        |> Repo.all()

      %{actor | memberships: memberships}
    else
      actor
    end
  end

  defp list_blacklisted_groups(attrs) do
    (Map.get(attrs, "memberships") || Map.get(attrs, :memberships) || [])
    |> Enum.flat_map(fn membership ->
      if group_id = Map.get(membership, "group_id") || Map.get(membership, :group_id) do
        [group_id]
      else
        []
      end
    end)
    |> case do
      [] ->
        []

      group_ids ->
        Group.Query.by_id({:in, group_ids})
        |> Group.Query.by_not_empty_provider_id()
        |> Repo.all()
    end
  end

  def disable_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          if actor.type != :account_admin_user or other_enabled_admins_exist?(actor) do
            {:ok, _tokens} = Tokens.delete_tokens_for(actor, subject)
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

  def delete_actor(%Actor{last_synced_at: nil} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          if actor.type != :account_admin_user or other_enabled_admins_exist?(actor) do
            :ok = Auth.delete_identities_for(actor, subject)
            :ok = Clients.delete_clients_for(actor, subject)

            {_count, nil} =
              Membership.Query.by_actor_id(actor.id)
              |> Repo.delete_all()

            {:ok, _tokens} = Tokens.delete_tokens_for(actor, subject)

            Actor.Changeset.delete_actor(actor)
          else
            :cant_delete_the_last_admin
          end
        end
      )
    end
  end

  def actor_synced?(%Actor{last_synced_at: nil}), do: false
  def actor_synced?(%Actor{}), do: true

  def actor_deleted?(%Actor{deleted_at: nil}), do: false
  def actor_deleted?(%Actor{}), do: true

  def actor_disabled?(%Actor{disabled_at: nil}), do: false
  def actor_disabled?(%Actor{}), do: true

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
