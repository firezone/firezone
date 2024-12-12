defmodule Domain.Resources do
  alias Domain.{Repo, Auth, PubSub}
  alias Domain.{Accounts, Gateways, Policies, Flows}
  alias Domain.Resources.{Authorizer, Resource, Connection}

  def fetch_resource_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Resource.Query.all()
      |> Resource.Query.by_id(id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch(Resource.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_resource_by_id_or_persistent_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Resource.Query.all()
      |> Resource.Query.by_id_or_persistent_id(id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch(Resource.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_active_resource_by_id_or_persistent_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id_or_persistent_id(id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch(Resource.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_and_authorize_resource_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_available_resources_permission()),
         true <- Repo.valid_uuid?(id) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id(id)
      |> Resource.Query.by_account_id(subject.account.id)
      |> Resource.Query.by_authorized_actor_id(subject.actor.id)
      |> Repo.fetch(Resource.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_resource_by_id!(id) do
    if Repo.valid_uuid?(id) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id(id)
      |> Repo.one!()
    else
      {:error, :not_found}
    end
  end

  def fetch_resource_by_id_or_persistent_id!(id) do
    if Repo.valid_uuid?(id) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id_or_persistent_id(id)
      |> Repo.one!()
    else
      {:error, :not_found}
    end
  end

  def all_authorized_resources(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_available_resources_permission()) do
      {preload, opts} = Keyword.pop(opts, :preload, [])

      resources =
        Resource.Query.not_deleted()
        |> Resource.Query.by_account_id(subject.account.id)
        |> Resource.Query.by_authorized_actor_id(subject.actor.id)
        |> Resource.Query.with_at_least_one_gateway_group()
        |> Repo.all(opts)
        |> Repo.preload(preload)

      {:ok, resources}
    end
  end

  def all_resources!(%Auth.Subject{} = subject) do
    Resource.Query.not_deleted()
    |> Resource.Query.by_account_id(subject.account.id)
    |> Resource.Query.filter_features(subject.account)
    |> Authorizer.for_subject(Resource, subject)
    |> Repo.all()
  end

  def list_resources(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.not_deleted()
      |> Resource.Query.filter_features(subject.account)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.list(Resource.Query, opts)
    end
  end

  def all_resources!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Resource.Query.not_deleted()
    |> Resource.Query.filter_features(subject.account)
    |> Authorizer.for_subject(Resource, subject)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def count_resources_for_gateway(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      count =
        Resource.Query.not_deleted()
        |> Authorizer.for_subject(Resource, subject)
        |> Resource.Query.by_gateway_group_id(gateway.group_id)
        |> Repo.aggregate(:count)

      {:ok, count}
    end
  end

  def list_resources_for_gateway(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      resources =
        Resource.Query.not_deleted()
        |> Resource.Query.by_account_id(subject.account.id)
        |> Resource.Query.by_gateway_group_id(gateway.group_id)
        |> Repo.all()

      {:ok, resources}
    end
  end

  def peek_resource_actor_groups(resources, limit, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      ids = resources |> Enum.map(& &1.id) |> Enum.uniq()

      {:ok, peek} =
        Resource.Query.not_deleted()
        |> Resource.Query.by_id({:in, ids})
        |> Authorizer.for_subject(Resource, subject)
        |> Resource.Query.preload_few_actor_groups_for_each_resource(limit)
        |> Repo.peek(resources)

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

  def new_resource(%Accounts.Account{} = account, attrs \\ %{}) do
    Resource.Changeset.create(account, attrs)
  end

  def create_resource(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      changeset = Resource.Changeset.create(subject.account, attrs, subject)

      with {:ok, resource} <- Repo.insert(changeset) do
        :ok = broadcast_resource_events(:create, resource)
        {:ok, resource}
      end
    end
  end

  def create_internet_resource(%Accounts.Account{} = account) do
    attrs = %{type: :internet, name: "Internet"}
    changeset = Resource.Changeset.create(account, attrs)

    with {:ok, resource} <- Repo.insert(changeset) do
      :ok = broadcast_resource_events(:create, resource)
      {:ok, resource}
    end
  end

  def change_resource(%Resource{} = resource, attrs \\ %{}, %Auth.Subject{} = subject) do
    case Resource.Changeset.update_or_replace(resource, attrs, subject) do
      {update_changeset, nil} -> update_changeset
      {_update_changeset, create_changeset} -> create_changeset
    end
  end

  def update_or_replace_resource(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id(resource.id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch_and_update_or_replace(Resource.Query,
        with: fn resource ->
          resource
          |> Repo.preload(:connections)
          |> Resource.Changeset.update_or_replace(attrs, subject)
        end,
        on_replace: fn repo, updated_resource, created_resource ->
          Ecto.Changeset.change(updated_resource, replaced_by_resource_id: created_resource.id)
          |> repo.update()
        end,
        after_update_commit: fn resource, changeset ->
          if Map.has_key?(changeset.changes, :connections) do
            {:ok, _flows} = Flows.expire_flows_for(resource, subject)
          end

          broadcast_resource_events(:update, resource)
        end,
        after_replace_commit: fn {replaced_resource, created_resource}, _changesets ->
          replaced_resource = Repo.preload(replaced_resource, :policies)

          :ok =
            Enum.each(replaced_resource.policies, fn policy ->
              {:replaced, _replaced_policy, _created_policy} =
                Policies.update_or_replace_policy(
                  policy,
                  %{resource_id: created_resource.id},
                  subject
                )
            end)

          {:ok, _flows} = Flows.expire_flows_for(replaced_resource, subject)
          :ok = broadcast_resource_events(:delete, replaced_resource)
          :ok = broadcast_resource_events(:create, created_resource)
        end
      )
    end
  end

  def delete_resource(%Resource{type: :internet}, %Auth.Subject{}) do
    {:error, :cannot_delete_internet_resource}
  end

  def delete_resource(%Resource{} = resource, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id(resource.id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch_and_update(Resource.Query,
        with: fn resource ->
          {_count, nil} =
            Connection.Query.by_resource_id(resource.id)
            |> Repo.delete_all()

          Resource.Changeset.delete(resource)
        end
      )
      |> case do
        {:ok, resource} ->
          :ok = broadcast_resource_events(:delete, resource)
          {:ok, _policies} = Policies.delete_policies_for(resource, subject)
          {:ok, resource}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_connections_for(%Gateways.Group{} = gateway_group, %Auth.Subject{} = subject) do
    Connection.Query.by_gateway_group_id(gateway_group.id)
    |> delete_connections(subject)
  end

  defp delete_connections(queryable, subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      {count, nil} =
        queryable
        |> Authorizer.for_subject(Connection, subject)
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  def connected?(
        %Resource{account_id: account_id} = resource,
        %Gateways.Gateway{account_id: account_id} = gateway
      ) do
    Connection.Query.by_resource_id(resource.id)
    |> Connection.Query.by_gateway_group_id(gateway.group_id)
    |> Repo.exists?()
  end

  ### PubSub

  defp resource_topic(%Resource{} = resource), do: resource_topic(resource.id)
  defp resource_topic(resource_id), do: "resource:#{resource_id}"

  defp account_topic(%Accounts.Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "account_policies:#{account_id}"

  def subscribe_to_events_for_resource(resource_or_id) do
    resource_or_id |> resource_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_for_resource(resource_or_id) do
    resource_or_id |> resource_topic() |> PubSub.unsubscribe()
  end

  def subscribe_to_events_for_account(account_or_id) do
    account_or_id |> account_topic() |> PubSub.subscribe()
  end

  defp broadcast_resource_events(action, %Resource{} = resource) do
    payload = {:"#{action}_resource", resource.id}
    :ok = broadcast_to_resource(resource, payload)
    :ok = broadcast_to_account(resource.account_id, payload)
    :ok
  end

  defp broadcast_to_resource(resource_or_id, payload) do
    resource_or_id
    |> resource_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_account(account_or_id, payload) do
    account_or_id
    |> account_topic()
    |> PubSub.broadcast(payload)
  end

  @doc false
  # This is the code that will be removed in future version of Firezone (in 1.3-1.4)
  # and is reused to prevent breaking changes
  def map_resource_address(address, acc \\ "")

  def map_resource_address(["*", "*" | rest], ""),
    do: map_resource_address(rest, "*")

  def map_resource_address(["*", "*" | _rest], _acc),
    do: :drop

  def map_resource_address(["*" | rest], ""),
    do: map_resource_address(rest, "?")

  def map_resource_address(["*" | _rest], _acc),
    do: :drop

  def map_resource_address(["?" | _rest], _acc),
    do: :drop

  def map_resource_address([char | rest], acc),
    do: map_resource_address(rest, acc <> char)

  def map_resource_address([], acc),
    do: {:cont, acc}
end
