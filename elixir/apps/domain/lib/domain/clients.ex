defmodule Domain.Clients do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  alias Domain.{Accounts, Actors}
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
    Client.Query.by_account_id(account_id)
    |> Repo.aggregate(:count)
  end

  def count_by_actor_id(actor_id) do
    Client.Query.by_actor_id(actor_id)
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
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Client.Query.all()
      |> Client.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, client} ->
          client =
            client
            |> Repo.preload(preload)
            |> preload_online_status()

          {:ok, client}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_client_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Client.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
    |> preload_online_status()
  end

  def list_clients(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      {:ok, clients} =
        Client.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Ecto.Query.order_by([clients: clients], desc: clients.last_seen_at, desc: clients.id)
        |> Repo.list()

      clients =
        clients
        |> preload_online_statuses()

      {:ok, Repo.preload(clients, preload)}
    end
  end

  def list_clients_for_actor(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    list_clients_by_actor_id(actor.id, subject)
  end

  def list_clients_by_actor_id(actor_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(actor_id) do
      {:ok, clients} =
        Client.Query.by_actor_id(actor_id)
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      clients =
        clients
        |> preload_online_statuses()

      {:ok, clients}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # TODO: this is ugly!
  defp preload_online_status(client) do
    case Presence.get_by_key("clients:#{client.account_id}", client.id) do
      [] -> %{client | online?: false}
      %{metas: [_ | _]} -> %{client | online?: true}
    end
  end

  def preload_online_statuses([]), do: []

  def preload_online_statuses([client | _] = clients) do
    connected_clients = Presence.list("clients:#{client.account_id}")

    Enum.map(clients, fn client ->
      %{client | online?: Map.has_key?(connected_clients, client.id)}
    end)
  end

  def change_client(%Client{} = client, attrs \\ %{}) do
    Client.Changeset.update(client, attrs)
  end

  def upsert_client(attrs \\ %{}, %Auth.Subject{identity: %Auth.Identity{} = identity} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_clients_permission()) do
      changeset = Client.Changeset.upsert(identity, subject.context, attrs)

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
      Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Client.Changeset.update(&1, attrs))
      |> case do
        {:ok, client} ->
          {:ok, preload_online_status(client)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_client(%Client{} = client, %Auth.Subject{} = subject) do
    with :ok <- authorize_actor_client_management(client.actor_id, subject) do
      Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Client.Changeset.delete/1)
    end
  end

  def delete_actor_clients(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_clients_permission()) do
      {_count, nil} =
        Client.Query.by_actor_id(actor.id)
        |> Client.Query.by_account_id(actor.account_id)
        |> Authorizer.for_subject(subject)
        |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

      :ok
    end
  end

  def authorize_actor_client_management(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    authorize_actor_client_management(actor.id, subject)
  end

  def authorize_actor_client_management(actor_id, %Auth.Subject{actor: %{id: actor_id}} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_own_clients_permission())
  end

  def authorize_actor_client_management(_actor_id, %Auth.Subject{} = subject) do
    Auth.ensure_has_permissions(subject, Authorizer.manage_clients_permission())
  end

  def connect_client(%Client{} = client) do
    {:ok, _} =
      Presence.track(self(), "clients:#{client.account_id}", client.id, %{
        online_at: System.system_time(:second)
      })

    {:ok, _} = Presence.track(self(), "actor_clients:#{client.actor_id}", client.id, %{})

    :ok
  end

  def subscribe_for_clients_presence_in_account(%Accounts.Account{} = account) do
    subscribe_for_clients_presence_in_account(account.id)
  end

  def subscribe_for_clients_presence_in_account(account_id) do
    Phoenix.PubSub.subscribe(Domain.PubSub, "clients:#{account_id}")
  end

  def subscribe_for_clients_presence_for_actor(%Actors.Actor{} = actor) do
    Phoenix.PubSub.subscribe(Domain.PubSub, "actor_clients:#{actor.id}")
  end

  def fetch_client_config!(%Client{} = client) do
    %{
      clients_upstream_dns: upstream_dns
    } = Domain.Config.fetch_resolved_configs!(client.account_id, [:clients_upstream_dns])

    [upstream_dns: upstream_dns]
  end
end
