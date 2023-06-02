defmodule Domain.Resources do
  alias Domain.{Repo, Validator, Auth}
  alias Domain.Resources.{Authorizer, Resource}

  def fetch_resource_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()),
         true <- Validator.valid_uuid?(id) do
      Resource.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
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

  def list_resources(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_resources_permission(),
         Authorizer.view_available_resources_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      # TODO: maybe we need to also enrich the data and show if it's online or not
      Resource.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def create_resource(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      changeset = Resource.Changeset.create_changeset(subject.account, attrs)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:resource, changeset, returning: true)
      |> resolve_address_multi(:ipv4)
      |> resolve_address_multi(:ipv6)
      |> Ecto.Multi.update(:resource_with_address, fn
        %{resource: %Resource{} = resource, ipv4: ipv4, ipv6: ipv6} ->
          Resource.Changeset.finalize_create_changeset(resource, ipv4, ipv6)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{resource_with_address: resource}} ->
          # TODO: Add optimistic lock to resource.updated_at to serialize the resource updates
          # TODO: Broadcast only to actors that have access to the resource
          # {:ok, actors} = list_authorized_actors(resource)
          # Phoenix.PubSub.broadcast(
          #   Domain.PubSub,
          #   "actor_device:#{subject.actor.id}",
          #   {:resource_added, resource.id}
          # )

          {:ok, resource}

        {:error, :resource, changeset, _effects_so_far} ->
          {:error, changeset}
      end
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{resource: %Resource{} = resource} ->
      if address = Map.get(resource, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(resource.account_id, type)}
      end
    end)
  end

  def update_resource(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_resources_permission()) do
      resource
      |> Resource.Changeset.update_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, resource} ->
          # Phoenix.PubSub.broadcast(
          #   Domain.PubSub,
          #   "actor_device:#{resource.actor_id}",
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
      |> Repo.fetch_and_update(with: &Resource.Changeset.delete_changeset/1)
      |> case do
        {:ok, resource} ->
          # Phoenix.PubSub.broadcast(
          #   Domain.PubSub,
          #   "actor_device:#{resource.actor_id}",
          #   {:resource_removed, resource.id}
          # )

          {:ok, resource}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
