defmodule Domain.Clients do
  use Supervisor
  alias Domain.{Repo, Auth, Safe}
  alias Domain.{Accounts, Actors}
  alias Domain.Clients.{Client, Presence}
  require Ecto.Query

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def count_by_account_id(account_id) do
    Client.Query.all()
    |> Client.Query.by_account_id(account_id)
    |> Repo.aggregate(:count)
  end

  def count_1m_active_users_for_account(%Accounts.Account{} = account) do
    Client.Query.all()
    |> Client.Query.by_account_id(account.id)
    |> Client.Query.by_last_seen_within(1, "month")
    |> Client.Query.select_distinct_actor_id()
    |> Client.Query.only_for_active_actors()
    |> Client.Query.by_actor_type({:in, [:account_user, :account_admin_user]})
    |> Repo.aggregate(:count)
  end

  def count_by_actor_id(actor_id) do
    Client.Query.all()
    |> Client.Query.by_actor_id(actor_id)
    |> Repo.aggregate(:count)
  end

  def count_incompatible_for(account, gateway_version) do
    Client.Query.all()
    |> Client.Query.by_account_id(account.id)
    |> Client.Query.by_last_seen_within(1, "week")
    |> Client.Query.by_incompatible_for(gateway_version)
    |> Client.Query.only_for_active_actors()
    |> Repo.aggregate(:count)
  end

  def fetch_client_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Client.Query.all()
        |> Client.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        client -> {:ok, client}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_client_by_id!(id, opts \\ []) do
    Client.Query.all()
    |> Client.Query.by_id(id)
    |> Repo.fetch!(Client.Query, opts)
  end

  def list_clients(%Auth.Subject{} = subject, opts \\ []) do
    Client.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Client.Query, opts)
  end

  def list_clients_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts) do
    list_clients_by_actor_id(actor.id, subject, opts)
  end

  def list_clients_by_actor_id(actor_id, %Auth.Subject{} = subject, opts \\ []) do
    with true <- Repo.valid_uuid?(actor_id) do
      Client.Query.all()
      |> Client.Query.by_actor_id(actor_id)
      |> Safe.scoped(subject)
      |> Safe.list(Client.Query, opts)
    else
      false -> {:ok, [], Repo.Paginator.empty_metadata()}
    end
  end

  @doc false
  def preload_clients_presence([client]) do
    Presence.Account.get(client.account_id, client.id)
    |> case do
      [] -> %{client | online?: false}
      %{metas: [_ | _]} -> %{client | online?: true}
    end
    |> List.wrap()
  end

  def preload_clients_presence(clients) do
    # we fetch list of account clients for every account_id present in the clients list
    connected_clients =
      clients
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce([], fn account_id, acc ->
        connected_client_ids = online_client_ids(account_id)
        connected_client_ids ++ acc
      end)

    Enum.map(clients, fn client ->
      %{client | online?: client.id in connected_clients}
    end)
  end

  def online_client_ids(account_id) do
    account_id
    |> Presence.Account.list()
    |> Map.keys()
  end

  def change_client(%Client{} = client, attrs \\ %{}) do
    Client.Changeset.update(client, attrs)
  end

  def upsert_client(attrs \\ %{}, %Auth.Subject{} = subject) do
    changeset = Client.Changeset.upsert(subject.actor, subject, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:client, changeset,
      conflict_target: Client.Changeset.upsert_conflict_target(),
      on_conflict: Client.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> resolve_address_multi(:ipv4)
    |> resolve_address_multi(:ipv6)
    |> Ecto.Multi.update(:client_with_address, fn
      %{client: %Client{} = client, ipv4: ipv4, ipv6: ipv6} ->
        Client.Changeset.finalize_upsert(client, ipv4, ipv6)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{client_with_address: client}} -> {:ok, client}
      {:error, :client, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{client: %Client{} = client} ->
      if address = Map.get(client, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(client.account_id, type)}
      end
    end)
  end

  def update_client(%Client{} = client, attrs, %Auth.Subject{} = subject) do
    changeset = Client.Changeset.update(client, attrs)

    case Safe.scoped(changeset, subject) |> Safe.update() do
      {:ok, updated_client} ->
        {:ok, preload_clients_presence([updated_client]) |> List.first()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_client(%Client{} = client, %Auth.Subject{} = subject) do
    # Only account_admin_user can verify clients
    if subject.actor.type == :account_admin_user do
      changeset = Client.Changeset.verify(client, subject)

      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  def remove_client_verification(%Client{} = client, %Auth.Subject{} = subject) do
    # Only account_admin_user can remove client verification
    if subject.actor.type == :account_admin_user do
      changeset = Client.Changeset.remove_verification(client)

      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  def delete_client(%Client{} = client, %Auth.Subject{} = subject) do
    case Safe.scoped(client, subject) |> Safe.delete() do
      {:ok, deleted_client} ->
        {:ok, preload_clients_presence([deleted_client]) |> List.first()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_clients_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    # Only account_admin_user can delete clients
    if subject.actor.type == :account_admin_user do
      queryable =
        Client.Query.all()
        |> Client.Query.by_actor_id(actor.id)
        |> Client.Query.by_account_id(actor.account_id)

      delete_clients(queryable, subject)
    else
      {:error, :unauthorized}
    end
  end

  # We don't necessarily want to delete associated tokens when deleting a client because
  # that token could be a multi-owner token in the case of a headless client.
  # Instead we need to introduce the concept of ephemeral clients/gateways and permanent ones.
  defp delete_clients(queryable, subject) do
    {_count, nil} =
      queryable
      |> Safe.scoped(subject)
      |> Safe.delete_all()

    :ok
  end
end
