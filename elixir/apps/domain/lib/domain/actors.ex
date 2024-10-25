defmodule Domain.Actors do
  alias Domain.Actors.Membership
  alias Web.Clients
  alias Domain.{Repo, PubSub}
  alias Domain.{Accounts, Auth, Tokens, Clients, Policies, Billing}
  alias Domain.Actors.{Authorizer, Actor, Group}
  require Ecto.Query

  # Groups

  def fetch_groups_count_grouped_by_provider_id(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      groups =
        Group.Query.not_deleted()
        |> Group.Query.group_by_provider_id()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      groups =
        Enum.reduce(groups, %{}, fn %{provider_id: id, count: count}, acc ->
          Map.put(acc, id, count)
        end)

      {:ok, groups}
    end
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Repo.valid_uuid?(id) do
      Group.Query.all()
      |> Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Group.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Group.Query, opts)
    end
  end

  def list_groups_for(%Actor{} = actor, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.by_actor_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Group.Query, opts)
    end
  end

  def all_groups!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Group.Query.not_deleted()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def all_editable_groups!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Group.Query.not_deleted()
    |> Group.Query.editable()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def list_editable_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.editable()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Group.Query, opts)
    end
  end

  def peek_group_actors(groups, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      ids = groups |> Enum.map(& &1.id) |> Enum.uniq()

      Group.Query.not_deleted()
      |> Group.Query.by_id({:in, ids})
      |> Group.Query.preload_few_actors_for_each_group(limit)
      |> Authorizer.for_subject(subject)
      |> Repo.peek(groups)
    end
  end

  def peek_actor_groups(actors, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      ids = actors |> Enum.map(& &1.id) |> Enum.uniq()

      {:ok, peek} =
        Actor.Query.not_deleted()
        |> Actor.Query.by_id({:in, ids})
        |> Actor.Query.preload_few_groups_for_each_actor(limit)
        |> Authorizer.for_subject(subject)
        |> Repo.peek(actors)

      group_by_ids =
        Enum.flat_map(peek, fn {_id, %{items: items}} -> items end)
        |> Repo.preload(:provider)
        |> Enum.map(&{&1.id, &1})
        |> Enum.into(%{})

      peek =
        for {id, %{items: items} = map} <- peek, into: %{} do
          {id, %{map | items: Enum.map(items, &Map.fetch!(group_by_ids, &1.id))}}
        end

      {:ok, peek}
    end
  end

  def peek_actor_clients(actors, limit, %Auth.Subject{} = subject) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Clients.Authorizer.manage_clients_permission()) do
      ids = actors |> Enum.map(& &1.id) |> Enum.uniq()

      {:ok, peek} =
        Actor.Query.not_deleted()
        |> Actor.Query.by_id({:in, ids})
        |> Actor.Query.preload_few_clients_for_each_actor(limit)
        |> Authorizer.for_subject(subject)
        |> Repo.peek(actors)

      group_by_ids =
        Enum.flat_map(peek, fn {_id, %{items: items}} -> items end)
        |> Clients.preload_clients_presence()
        |> Enum.map(&{&1.id, &1})
        |> Enum.into(%{})

      peek =
        for {id, %{items: items} = map} <- peek, into: %{} do
          {id, %{map | items: Enum.map(items, &Map.fetch!(group_by_ids, &1.id))}}
        end

      {:ok, peek}
    end
  end

  def sync_provider_groups(%Auth.Provider{} = provider, attrs_list) do
    Group.Sync.sync_provider_groups(provider, attrs_list)
  end

  def sync_provider_memberships(
        actor_ids_by_provider_identifier,
        group_ids_by_provider_identifier,
        %Auth.Provider{} = provider,
        tuples
      ) do
    Membership.Sync.sync_provider_memberships(
      actor_ids_by_provider_identifier,
      group_ids_by_provider_identifier,
      provider,
      tuples
    )
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_managed_group(%Accounts.Account{} = account, attrs) do
    changeset = Group.Changeset.create(account, attrs)

    case Repo.insert(changeset) do
      {:ok, group} ->
        :ok = broadcast_group_memberships_events(group, changeset)
        {:ok, group}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      changeset = Group.Changeset.create(subject.account, attrs, subject)

      case Repo.insert(changeset) do
        {:ok, group} ->
          :ok = broadcast_group_memberships_events(group, changeset)
          {:ok, group}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def change_group(group, attrs \\ %{})

  def change_group(%Group{type: :managed}, _attrs) do
    raise ArgumentError, "can't change managed groups"
  end

  def change_group(%Group{provider_id: nil} = group, attrs) do
    Group.Changeset.update(group, attrs)
  end

  def change_group(%Group{}, _attrs) do
    raise ArgumentError, "can't change synced groups"
  end

  def update_group(%Group{type: :managed}, _attrs, %Auth.Subject{}) do
    {:error, :managed_group}
  end

  def update_group(%Group{provider_id: nil} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Group.Query,
        with: fn group ->
          group
          |> Repo.preload(:memberships)
          |> Group.Changeset.update(attrs)
        end,
        after_commit: fn _actor, changeset -> broadcast_memberships_events(changeset) end
      )
    end
  end

  def update_group(%Group{}, _attrs, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def update_dynamic_group_memberships(account_id) do
    Repo.transaction(fn ->
      Group.Query.not_deleted()
      |> Group.Query.by_account_id(account_id)
      |> Group.Query.by_type({:in, [:dynamic, :managed]})
      |> Group.Query.lock()
      |> Repo.all()
      |> Enum.map(fn group ->
        changeset =
          group
          |> Repo.preload(:memberships)
          |> Ecto.Changeset.change()
          |> Group.Changeset.put_dynamic_memberships(account_id)

        {:ok, group} = Repo.update(changeset)

        :ok = broadcast_memberships_events(changeset)

        group
      end)
    end)
  end

  def delete_group(%Group{provider_id: nil} = group, %Auth.Subject{} = subject) do
    queryable =
      Group.Query.not_deleted()
      |> Group.Query.by_id(group.id)

    case delete_groups(queryable, subject) do
      {:ok, [group]} ->
        {:ok, _policies} = Policies.delete_policies_for(group, subject)

        {_count, memberships} =
          Membership.Query.all()
          |> Membership.Query.by_group_id(group.id)
          |> Membership.Query.returning_all()
          |> Repo.delete_all()

        :ok = broadcast_membership_removal_events(memberships)

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
      Group.Query.not_deleted()
      |> Group.Query.by_provider_id(provider.id)
      |> Group.Query.by_account_id(provider.account_id)

    {_count, memberships} =
      Membership.Query.by_group_provider_id(provider.id)
      |> Membership.Query.returning_all()
      |> Repo.delete_all()

    :ok = broadcast_membership_removal_events(memberships)

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

  @doc false
  # used in sync workers
  def delete_groups(queryable) do
    {_count, groups} =
      queryable
      |> Group.Query.delete()
      |> Repo.update_all([])

    :ok =
      Enum.each(groups, fn group ->
        {:ok, _policies} = Domain.Policies.delete_policies_for(group)
      end)

    {_count, memberships} =
      Membership.Query.by_group_id({:in, Enum.map(groups, & &1.id)})
      |> Membership.Query.returning_all()
      |> Repo.delete_all()

    :ok = broadcast_membership_removal_events(memberships)

    {:ok, groups}
  end

  def group_synced?(%Group{provider_id: nil}), do: false
  def group_synced?(%Group{}), do: true

  def group_managed?(%Group{type: :managed}), do: true
  def group_managed?(%Group{}), do: false

  def group_editable?(%Group{} = group),
    do: not group_deleted?(group) and not group_synced?(group) and not group_managed?(group)

  def group_deleted?(%Group{deleted_at: nil}), do: false
  def group_deleted?(%Group{}), do: true

  # Actors

  def count_users_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type({:in, [:account_admin_user, :account_user]})
    |> Repo.aggregate(:count)
  end

  def count_account_admin_users_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:account_admin_user)
    |> Repo.aggregate(:count)
  end

  def count_service_accounts_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:service_account)
    |> Repo.aggregate(:count)
  end

  def count_synced_actors_for_provider(%Auth.Provider{} = provider) do
    Actor.Query.not_deleted()
    |> Actor.Query.by_deleted_identity_provider_id(provider.id)
    |> Actor.Query.by_stale_for_provider(provider.id)
    |> Repo.all()

    Actor.Query.not_deleted()
    |> Actor.Query.by_deleted_identity_provider_id(provider.id)
    |> Actor.Query.by_stale_for_provider(provider.id)
    |> Repo.aggregate(:count)
  end

  def fetch_actor_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Repo.valid_uuid?(id) do
      Actor.Query.all()
      |> Actor.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Actor.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_active_actor_by_id(id) do
    if Repo.valid_uuid?(id) do
      Actor.Query.not_disabled()
      |> Actor.Query.by_id(id)
      |> Repo.fetch(Actor.Query, [])
    else
      {:error, :not_found}
    end
  end

  def all_actor_group_ids!(%Actor{} = actor) do
    Membership.Query.by_actor_id(actor.id)
    |> Membership.Query.select_distinct_group_ids()
    |> Repo.all()
  end

  def preload_last_seen_at(actors) do
    actor_ids = Enum.map(actors, & &1.id)
    last_seen_at = Auth.max_last_seen_at_by_actor_ids(actor_ids)

    Enum.map(actors, fn actor ->
      %{actor | last_seen_at: Map.get(last_seen_at, actor.id)}
    end)
  end

  def all_admins_for_account!(%Accounts.Account{} = account, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:account_admin_user)
    |> Repo.all(opts)
    |> Repo.preload(preload)
  end

  def list_actors(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Actor.Query, opts)
    end
  end

  def new_actor(attrs \\ %{memberships: []}) do
    Actor.Changeset.create(attrs)
  end

  def create_actor(%Accounts.Account{} = account, attrs) do
    Actor.Changeset.create(account.id, attrs)
    |> Repo.insert()
  end

  def create_actor(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account),
         changeset = Actor.Changeset.create(account.id, attrs, subject),
         :ok <- ensure_billing_limits_not_exceeded(account, changeset) do
      Repo.insert(changeset)
    end
  end

  defp ensure_billing_limits_not_exceeded(account, %{valid?: true} = changeset) do
    case Ecto.Changeset.fetch_field!(changeset, :type) do
      :service_account ->
        if Billing.can_create_service_accounts?(account) do
          :ok
        else
          {:error, :service_accounts_limit_reached}
        end

      :account_admin_user ->
        if Billing.can_create_users?(account) and Billing.can_create_admin_users?(account) do
          :ok
        else
          {:error, :seats_limit_reached}
        end

      :account_user ->
        if Billing.can_create_users?(account) do
          :ok
        else
          {:error, :seats_limit_reached}
        end

      _other ->
        :ok
    end
  end

  defp ensure_billing_limits_not_exceeded(_account, _changeset) do
    # we return :ok because we want Repo.insert() call to still put action and
    # rest of possible metadata if there are validation errors
    :ok
  end

  def change_actor(%Actor{} = actor, attrs \\ %{}) do
    Actor.Changeset.update(actor, [], attrs)
  end

  def update_actor(%Actor{} = actor, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.not_deleted()
      |> Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Actor.Query,
        with: fn actor ->
          actor = maybe_preload_editable_memberships(actor, attrs)
          synced_groups = list_readonly_groups(attrs)
          changeset = Actor.Changeset.update(actor, attrs, synced_groups, subject)

          cond do
            changeset.data.type != :account_admin_user -> changeset
            Map.get(changeset.changes, :type) == :account_admin_user -> changeset
            other_enabled_admins_exist?(actor) -> changeset
            is_nil(Map.get(changeset.changes, :type)) -> changeset
            true -> :cant_remove_admin_type
          end
        end,
        after_commit: fn _actor, changeset -> broadcast_memberships_events(changeset) end
      )
    end
  end

  defp maybe_preload_editable_memberships(%Actor{} = actor, attrs) do
    if Map.has_key?(attrs, "memberships") || Map.has_key?(attrs, :memberships) do
      memberships =
        Membership.Query.by_actor_id(actor.id)
        |> Membership.Query.only_editable_groups()
        |> Membership.Query.lock()
        |> Repo.all()

      %{actor | memberships: memberships}
    else
      actor
    end
  end

  defp list_readonly_groups(attrs) do
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
        Group.Query.not_deleted()
        |> Group.Query.not_editable()
        |> Group.Query.by_id({:in, group_ids})
        |> Repo.all()
    end
  end

  def disable_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.not_deleted()
      |> Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Actor.Query,
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
      Actor.Query.not_deleted()
      |> Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Actor.Query, with: &Actor.Changeset.enable_actor/1)
    end
  end

  def delete_actor(%Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.not_deleted()
      |> Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Actor.Query,
        with: fn actor ->
          if actor.type != :account_admin_user or other_enabled_admins_exist?(actor) do
            :ok = Auth.delete_identities_for(actor, subject)
            :ok = Clients.delete_clients_for(actor, subject)

            {_count, memberships} =
              Membership.Query.by_actor_id(actor.id)
              |> Membership.Query.returning_all()
              |> Repo.delete_all()

            {:ok, _groups} = update_dynamic_group_memberships(actor.account_id)
            :ok = broadcast_membership_removal_events(memberships)
            {:ok, _tokens} = Tokens.delete_tokens_for(actor, subject)

            Actor.Changeset.delete_actor(actor)
          else
            :cant_delete_the_last_admin
          end
        end
      )
    end
  end

  def delete_stale_synced_actors_for_provider(
        %Auth.Provider{} = provider,
        %Auth.Subject{} = subject
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Actor.Query.by_deleted_identity_provider_id(provider.id)
      |> Actor.Query.by_stale_for_provider(provider.id)
      |> Repo.all()
      |> Enum.each(fn actor ->
        {:ok, _actor} = delete_actor(actor, subject)
      end)
    end
  end

  def actor_synced?(%Actor{last_synced_at: nil}), do: false
  def actor_synced?(%Actor{}), do: true

  def actor_deleted?(%Actor{deleted_at: nil}), do: false
  def actor_deleted?(%Actor{}), do: true

  def actor_disabled?(%Actor{disabled_at: nil}), do: false
  def actor_disabled?(%Actor{}), do: true

  def actor_active?(%Actor{disabled_at: nil, deleted_at: nil}), do: true
  def actor_active?(%Actor{}), do: false

  defp other_enabled_admins_exist?(%Actor{
         type: :account_admin_user,
         account_id: account_id,
         id: id
       }) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_type(:account_admin_user)
    |> Actor.Query.by_account_id(account_id)
    |> Actor.Query.by_id({:not, id})
    |> Actor.Query.lock()
    |> Repo.exists?()
  end

  defp other_enabled_admins_exist?(%Actor{}) do
    false
  end

  ### PubSub

  defp actor_memberships_topic(%Actor{} = actor), do: actor_memberships_topic(actor.id)
  defp actor_memberships_topic(actor_id), do: "actor_memberships:#{actor_id}"

  def subscribe_to_membership_updates_for_actor(actor_or_id) do
    actor_or_id |> actor_memberships_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_membership_updates_for_actor(actor_or_id) do
    actor_or_id |> actor_memberships_topic() |> PubSub.unsubscribe()
  end

  defp broadcast_memberships_events(changeset) do
    if changeset.valid? and Ecto.Changeset.changed?(changeset, :memberships) do
      case Ecto.Changeset.apply_action(changeset, :update) do
        {:ok, %Actor{} = actor} ->
          broadcast_actor_memberships_events(actor, changeset)

        {:ok, %Group{} = group} ->
          broadcast_group_memberships_events(group, changeset)

        {:error, _reason} ->
          :ok
      end
    else
      :ok
    end
  end

  defp broadcast_actor_memberships_events(actor, changeset) do
    previous_group_ids =
      Map.get(changeset.data, :memberships, [])
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()

    current_group_ids =
      Map.get(actor, :memberships, [])
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()

    :ok =
      Enum.each(current_group_ids -- previous_group_ids, fn group_id ->
        broadcast_membership_event(:create, actor.id, group_id)
      end)

    :ok =
      Enum.each(previous_group_ids -- current_group_ids, fn group_id ->
        broadcast_membership_event(:delete, actor.id, group_id)
      end)
  end

  defp broadcast_group_memberships_events(group, changeset) do
    previous_actor_ids =
      Map.get(changeset.data, :memberships, [])
      |> Enum.map(& &1.actor_id)
      |> Enum.uniq()

    current_actor_ids =
      Map.get(group, :memberships, [])
      |> Enum.map(& &1.actor_id)
      |> Enum.uniq()

    :ok =
      Enum.each(current_actor_ids -- previous_actor_ids, fn actor_id ->
        broadcast_membership_event(:create, actor_id, group.id)
      end)

    :ok =
      Enum.each(previous_actor_ids -- current_actor_ids, fn actor_id ->
        broadcast_membership_event(:delete, actor_id, group.id)
      end)
  end

  defp broadcast_membership_removal_events(memberships) do
    Enum.each(memberships, fn membership ->
      broadcast_membership_event(:delete, membership.actor_id, membership.group_id)
    end)
  end

  def broadcast_membership_event(action, actor_id, group_id) do
    :ok = Policies.broadcast_access_events_for(action, actor_id, group_id)

    actor_id
    |> actor_memberships_topic()
    |> PubSub.broadcast({:"#{action}_membership", actor_id, group_id})
  end
end
