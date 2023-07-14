defmodule Domain.Actors do
  alias Domain.{Repo, Auth, Validator}
  alias Domain.Actors.{Authorizer, Actor, Group}
  require Ecto.Query

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Validator.valid_uuid?(id) do
      Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def upsert_provider_groups(%Auth.Provider{} = provider, attrs_by_provider_identifier) do
    attrs_by_provider_identifier
    |> Enum.reduce(Ecto.Multi.new(), fn {provider_identifier, attrs}, multi ->
      Ecto.Multi.insert(
        multi,
        {:group, provider_identifier},
        Group.Changeset.create_changeset(provider, provider_identifier, attrs),
        conflict_target: Group.Changeset.upsert_conflict_target(),
        on_conflict: Group.Changeset.upsert_on_conflict(),
        returning: true
      )
    end)
    |> Repo.transaction()

    # Ecto.Multi.new()
    # |> Ecto.Multi.insert(:actor, Actor.Changeset.create_changeset(provider, attrs))
    # |> Ecto.Multi.run(:identity, fn _repo, %{actor: actor} ->
    #   Auth.create_identity(actor, provider, provider_identifier)
    # end)
    # |> Repo.transaction()
    |> case do
      {:ok, %{group: group}} ->
        {:ok, group}

      {:error, _step, changeset, _effects_so_far} ->
        {:error, changeset}
    end
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      subject.account
      |> Group.Changeset.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:memberships)
    |> Group.Changeset.update_changeset(attrs)
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      group
      |> Repo.preload(:memberships)
      |> Group.Changeset.update_changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Group.Query.by_account_id(subject.account.id)
      |> Repo.fetch_and_update(with: &Group.Changeset.delete_changeset/1)
    end
  end

  def fetch_count_by_type(type, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_type(type)
      |> Authorizer.for_subject(subject)
      |> Repo.aggregate(:count)
    end
  end

  def fetch_actor_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         true <- Validator.valid_uuid?(id) do
      Actor.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      {hydrate, _opts} = Keyword.pop(opts, :hydrate, [])

      Actor.Query.all()
      |> Authorizer.for_subject(subject)
      # TODO: add filters
      |> hydrate_fields(hydrate)
      |> Repo.list()
    end
  end

  defp hydrate_fields(queryable, []), do: queryable

  def create_actor(
        %Auth.Provider{} = provider,
        provider_identifier,
        attrs,
        %Auth.Subject{} = subject
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()),
         :ok <- Auth.ensure_has_access_to(subject, provider),
         changeset = Actor.Changeset.create_changeset(provider, attrs),
         {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate) do
      granted_permissions = Auth.fetch_type_permissions!(data.type)

      if MapSet.subset?(granted_permissions, subject.permissions) do
        create_actor(provider, provider_identifier, attrs)
      else
        missing_permissions =
          MapSet.difference(granted_permissions, subject.permissions)
          |> MapSet.to_list()

        {:error, {:unauthorized, privilege_escalation: missing_permissions}}
      end
    end
  end

  def create_actor(%Auth.Provider{} = provider, provider_identifier, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:actor, Actor.Changeset.create_changeset(provider, attrs))
    |> Ecto.Multi.run(:identity, fn _repo, %{actor: actor} ->
      Auth.create_identity(actor, provider, provider_identifier)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{actor: actor, identity: identity}} ->
        {:ok, %{actor | identities: [identity]}}

      {:error, _step, changeset, _effects_so_far} ->
        {:error, changeset}
    end
  end

  def change_actor_type(%Actor{} = actor, type, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_actors_permission()) do
      Actor.Query.by_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn actor ->
          changeset = Actor.Changeset.set_actor_type(actor, type)

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
          if other_enabled_admins_exist?(actor) do
            Actor.Changeset.delete_actor(actor)
          else
            :cant_delete_the_last_admin
          end
        end
      )
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
