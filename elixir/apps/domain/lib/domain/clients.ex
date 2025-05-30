defmodule Domain.Clients do
  use Supervisor
  alias Domain.{Repo, Auth}
  alias Domain.{Accounts, Actors, Events, Flows}
  alias Domain.Clients.{Client, Authorizer, Presence}
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
    Client.Query.not_deleted()
    |> Client.Query.by_account_id(account_id)
    |> Repo.aggregate(:count)
  end

  def count_1m_active_users_for_account(%Accounts.Account{} = account) do
    Client.Query.not_deleted()
    |> Client.Query.by_account_id(account.id)
    |> Client.Query.by_last_seen_within(1, "month")
    |> Client.Query.select_distinct_actor_id()
    |> Client.Query.only_for_active_actors()
    |> Client.Query.by_actor_type({:in, [:account_user, :account_admin_user]})
    |> Repo.aggregate(:count)
  end

  def count_by_actor_id(actor_id) do
    Client.Query.not_deleted()
    |> Client.Query.by_actor_id(actor_id)
    |> Repo.aggregate(:count)
  end

  def fetch_client_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Client.Query.all()
      |> Client.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Client.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_client_by_id!(id, opts \\ []) do
    Client.Query.not_deleted()
    |> Client.Query.by_id(id)
    |> Repo.fetch!(Client.Query, opts)
  end

  def list_clients(%Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Client.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Client.Query, opts)
    end
  end

  def list_clients_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts) do
    list_clients_by_actor_id(actor.id, subject, opts)
  end

  def list_clients_by_actor_id(actor_id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(actor_id) do
      Client.Query.not_deleted()
      |> Client.Query.by_actor_id(actor_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Client.Query, opts)
    else
      false -> {:ok, [], Repo.Paginator.empty_metadata()}
      other -> other
    end
  end

  @doc false
  def preload_clients_presence([client]) do
    client.account_id
    |> Events.Hooks.Accounts.clients_presence_topic()
    |> Presence.get_by_key(client.id)
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
    |> Events.Hooks.Accounts.clients_presence_topic()
    |> Presence.list()
    |> Map.keys()
  end

  def change_client(%Client{} = client, attrs \\ %{}) do
    Client.Changeset.update(client, attrs)
  end

  def upsert_client(attrs \\ %{}, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_clients_permission()) do
      assoc = subject.identity || subject.actor
      changeset = Client.Changeset.upsert(assoc, subject, attrs)

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
    with :ok <- authorize_actor_client_management(client.actor_id, subject) do
      Client.Query.not_deleted()
      |> Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Client.Query,
        with: &Client.Changeset.update(&1, attrs),
        preload: [:online?]
      )
    end
  end

  def verify_client(%Client{} = client, %Auth.Subject{} = subject) do
    with :ok <- authorize_actor_client_management(client.actor_id, subject),
         :ok <- Auth.ensure_has_permissions(subject, Authorizer.verify_clients_permission()) do
      Client.Query.not_deleted()
      |> Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Client.Query,
        with: &Client.Changeset.verify(&1, subject),
        preload: [:online?]
      )
    end
  end

  def remove_client_verification(%Client{} = client, %Auth.Subject{} = subject) do
    with :ok <- authorize_actor_client_management(client.actor_id, subject),
         :ok <- Auth.ensure_has_permissions(subject, Authorizer.verify_clients_permission()) do
      Client.Query.not_deleted()
      |> Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Client.Query,
        with: &Client.Changeset.remove_verification(&1),
        preload: [:online?]
      )
      |> case do
        {:ok, client} ->
          {:ok, _flows} = Flows.expire_flows_for(client)
          {:ok, client}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_client(%Client{} = client, %Auth.Subject{} = subject) do
    queryable =
      Client.Query.not_deleted()
      |> Client.Query.by_id(client.id)

    with :ok <- authorize_actor_client_management(client.actor_id, subject) do
      case delete_clients(queryable, subject) do
        {:ok, [client]} ->
          {:ok, client}

        {:ok, []} ->
          {:error, :not_found}
      end
    end
  end

  def delete_clients_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    queryable =
      Client.Query.not_deleted()
      |> Client.Query.by_actor_id(actor.id)
      |> Client.Query.by_account_id(actor.account_id)

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_clients_permission()) do
      {:ok, _clients} = delete_clients(queryable, subject)
      :ok
    end
  end

  defp delete_clients(queryable, subject) do
    {_count, clients} =
      queryable
      |> Authorizer.for_subject(subject)
      |> Client.Query.delete()
      |> Repo.update_all([])

    {:ok, clients}
  end

  defp authorize_actor_client_management(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    authorize_actor_client_management(actor.id, subject)
  end

  defp authorize_actor_client_management(id, %Auth.Subject{actor: %{id: id}} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_own_clients_permission())
  end

  defp authorize_actor_client_management(_actor_id, %Auth.Subject{} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_clients_permission())
  end
end
