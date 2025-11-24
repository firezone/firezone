defmodule Domain.Resources do
  alias Domain.{Repo, Auth, Safe}
  alias Domain.{Accounts, Gateways}
  alias Domain.Resources.Resource
  require Logger
  import Ecto.Query, only: [where: 2]

  def fetch_resource_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Resource.Query.all()
        |> Resource.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_resource_by_id!(id) do
    if Repo.valid_uuid?(id) do
      Resource.Query.all()
      |> Resource.Query.by_id(id)
      |> Repo.one!()
    else
      {:error, :not_found}
    end
  end

  def fetch_internet_resource(%Accounts.Account{} = account) do
    Resource.Query.all()
    |> Resource.Query.by_account_id(account.id)
    |> Resource.Query.by_type(:internet)
    |> Repo.fetch(Resource.Query)
  end

  def fetch_internet_resource(%Auth.Subject{} = subject) do
    result =
      Resource.Query.all()
      |> Resource.Query.by_type(:internet)
      |> Safe.scoped(subject)
      |> Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      resource -> {:ok, resource}
    end
  end

  def fetch_all_resources_by_ids(ids) do
    Resource.Query.all()
    |> Resource.Query.by_id({:in, ids})
    |> Repo.all()
    |> Repo.preload(:gateway_groups)
  end

  def all_authorized_resources(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    resources =
      Resource.Query.all()
      |> Resource.Query.by_authorized_actor_id(subject.actor.id)
      |> Resource.Query.with_at_least_one_gateway_group()
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> []
        resources -> Repo.preload(resources, preload)
      end

    {:ok, resources}
  end

  def all_resources!(%Auth.Subject{} = subject) do
    Resource.Query.all()
    |> Resource.Query.filter_features(subject.account)
    |> Safe.scoped(subject)
    |> Safe.all()
    |> case do
      {:error, :unauthorized} -> []
      resources -> resources
    end
  end

  def all_resources!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Resource.Query.all()
    |> Resource.Query.filter_features(subject.account)
    |> Safe.scoped(subject)
    |> Safe.all()
    |> case do
      {:error, :unauthorized} -> []
      resources -> Repo.preload(resources, preload)
    end
  end

  def list_resources(%Auth.Subject{} = subject, opts \\ []) do
    Resource.Query.all()
    |> Resource.Query.filter_features(subject.account)
    |> Safe.scoped(subject)
    |> Safe.list(Resource.Query, opts)
  end

  def count_resources_for_gateway(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject) do
    count =
      Resource.Query.all()
      |> Resource.Query.by_gateway_group_id(gateway.group_id)
      |> where(account_id: ^subject.account.id)
      |> Repo.aggregate(:count)

    {:ok, count}
  end

  def list_resources_for_gateway(%Gateways.Gateway{} = gateway, %Auth.Subject{} = subject) do
    resources =
      Resource.Query.all()
      |> Resource.Query.by_gateway_group_id(gateway.group_id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> []
        resources -> resources
      end

    {:ok, resources}
  end

  def peek_resource_actor_groups(resources, limit, %Auth.Subject{} = subject) do
    ids = resources |> Enum.map(& &1.id) |> Enum.uniq()

    {:ok, peek} =
      Resource.Query.all()
      |> Resource.Query.by_id({:in, ids})
      |> Resource.Query.preload_few_actor_groups_for_each_resource(limit)
      |> where(account_id: ^subject.account.id)
      |> Repo.peek(resources)

    group_by_ids =
      Enum.flat_map(peek, fn {_id, %{items: items}} -> items end)
      |> Enum.map(&{&1.id, &1})
      |> Enum.into(%{})

    peek =
      for {id, %{items: items} = map} <- peek, into: %{} do
        {id, %{map | items: Enum.map(items, &Map.fetch!(group_by_ids, &1.id))}}
      end

    {:ok, peek}
  end

  def new_resource(%Accounts.Account{} = account, attrs \\ %{}) do
    Resource.Changeset.create(account, attrs)
  end

  def create_resource(attrs, %Auth.Subject{} = subject) do
    changeset = Resource.Changeset.create(subject.account, attrs, subject)

    Safe.scoped(changeset, subject)
    |> Safe.insert()
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
    changeset =
      resource
      |> Repo.preload(:connections)
      |> Resource.Changeset.update(attrs, subject)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def delete_resource(%Resource{type: :internet}, %Auth.Subject{}) do
    {:error, :cant_delete_internet_resource}
  end

  def delete_resource(%Resource{} = resource, %Auth.Subject{} = subject) do
    Safe.scoped(resource, subject)
    |> Safe.delete()
  end

  @doc """
    This does two things:
    1. Filters out resources that are not compatible with the given client or gateway version.
    2. Converts DNS resource addresses back to the pre-1.2.0 format if the client or gateway version is < 1.2.0.
  """
  def adapt_resource_for_version(resource, client_or_gateway_version) do
    cond do
      # internet resources require client and gateway >= 1.3.0
      resource.type == :internet and Version.match?(client_or_gateway_version, "< 1.3.0") ->
        nil

      # non-internet resource, pass as-is
      Version.match?(client_or_gateway_version, ">= 1.2.0") ->
        resource

      # we need convert dns resource addresses back to pre-1.2.0 format
      true ->
        resource.address
        |> String.codepoints()
        |> map_resource_address()
        |> case do
          {:cont, address} -> %{resource | address: address}
          :drop -> nil
        end
    end
  end

  defp map_resource_address(address, acc \\ "")

  defp map_resource_address(["*", "*" | rest], ""),
    do: map_resource_address(rest, "*")

  defp map_resource_address(["*", "*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["*" | rest], ""),
    do: map_resource_address(rest, "?")

  defp map_resource_address(["*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["?" | _rest], _acc),
    do: :drop

  defp map_resource_address([char | rest], acc),
    do: map_resource_address(rest, acc <> char)

  defp map_resource_address([], acc),
    do: {:cont, acc}
end
