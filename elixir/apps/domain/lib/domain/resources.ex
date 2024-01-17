defmodule Domain.Resources do
  alias Domain.{Repo, Validator, Auth}
  alias Domain.{Accounts, Gateways}
  alias Domain.Resources.{Authorizer, Resource, Connection}

  def fetch_resource_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Resource.Query.all()
      |> Resource.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, resource} -> {:ok, Repo.preload(resource, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_and_authorize_resource_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_available_resources_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Resource.Query.by_id(id)
      |> Resource.Query.by_account_id(subject.account.id)
      |> Resource.Query.by_authorized_actor_id(subject.actor.id)
      |> Repo.fetch()
      |> case do
        {:ok, resource} -> {:ok, Repo.preload(resource, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_resource_by_id!(id) do
    if Validator.valid_uuid?(id) do
      Resource.Query.by_id(id)
      |> Repo.one!()
    else
      {:error, :not_found}
    end
  end

  def list_authorized_resources(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_available_resources_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, resources} =
        Resource.Query.all()
        |> Resource.Query.by_account_id(subject.account.id)
        |> Resource.Query.by_authorized_actor_id(subject.actor.id)
        |> Resource.Query.with_at_least_one_gateway_group()
        |> Repo.list()

      {:ok, Repo.preload(resources, preload)}
    end
  end

  def list_resources(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, resources} =
        Resource.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(resources, preload)}
    end
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
        |> Authorizer.for_subject(subject)
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

      Resource.Query.by_id({:in, ids})
      |> Authorizer.for_subject(subject)
      |> Resource.Query.preload_few_actor_groups_for_each_resource(limit)
      |> Repo.peek(resources)
    end
  end

  def new_resource(%Accounts.Account{} = account, attrs \\ %{}) do
    Resource.Changeset.create(account, attrs)
  end

  def create_resource(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      changeset = Resource.Changeset.create(subject.account, attrs, subject)

      with {:ok, resource} <- Repo.insert(changeset) do
        # TODO: Add optimistic lock to resource.updated_at to serialize the resource updates
        # TODO: Broadcast only to actors that have access to the resource
        # {:ok, actors} = list_authorized_actors(resource)
        # Phoenix.PubSub.broadcast(
        #   Domain.PubSub,
        #   "actor_client:#{subject.actor.id}",
        #   {:resource_added, resource.id}
        # )

        {:ok, resource}
      end
    end
  end

  def change_resource(%Resource{} = resource, attrs \\ %{}, %Auth.Subject{} = subject) do
    Resource.Changeset.update(resource, attrs, subject)
  end

  def update_resource(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      resource
      |> Resource.Changeset.update(attrs, subject)
      |> Repo.update()
      |> case do
        {:ok, resource} ->
          # Phoenix.PubSub.broadcast(
          #   Domain.PubSub,
          #   "actor_client:#{resource.actor_id}",
          #   {:resource_updated, resource.id}
          # )

          {:ok, resource}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_resource(%Resource{} = resource, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      Resource.Query.by_id(resource.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Resource.Changeset.delete/1)
      |> case do
        {:ok, resource} ->
          # Phoenix.PubSub.broadcast(
          #   Domain.PubSub,
          #   "actor_client:#{resource.actor_id}",
          #   {:resource_removed, resource.id}
          # )

          {:ok, resource}

        {:error, reason} ->
          {:error, reason}
      end
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
end
