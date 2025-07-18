defmodule Domain.Resources do
  alias Domain.{Repo, Auth}
  alias Domain.{Accounts, Gateways, Policies}
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

  def fetch_internet_resource(%Accounts.Account{} = account) do
    Resource.Query.all()
    |> Resource.Query.by_account_id(account.id)
    |> Resource.Query.by_type(:internet)
    |> Repo.fetch(Resource.Query)
  end

  def fetch_internet_resource(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.all()
      |> Resource.Query.by_account_id(subject.account.id)
      |> Resource.Query.by_type(:internet)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch(Resource.Query, opts)
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
      Resource.Changeset.create(subject.account, attrs, subject)
      |> Repo.insert()
    end
  end

  def create_internet_resource(%Accounts.Account{} = account, %Gateways.Group{} = group) do
    attrs = %{
      type: :internet,
      name: "Internet",
      connections: %{
        group.id => %{
          gateway_group_id: group.id,
          enabled: true
        }
      }
    }

    Resource.Changeset.create(account, attrs)
    |> Repo.insert()
  end

  def change_resource(%Resource{} = resource, attrs \\ %{}, %Auth.Subject{} = subject) do
    Resource.Changeset.update(resource, attrs, subject)
  end

  def update_resource(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.not_deleted()
      |> Resource.Query.by_id(resource.id)
      |> Authorizer.for_subject(Resource, subject)
      |> Repo.fetch_and_update(Resource.Query,
        with: fn resource ->
          resource
          |> Repo.preload(:connections)
          |> Resource.Changeset.update(attrs, subject)
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

  def delete_connections_for(%Resource{} = resource, %Auth.Subject{} = subject) do
    Connection.Query.by_resource_id(resource.id)
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
