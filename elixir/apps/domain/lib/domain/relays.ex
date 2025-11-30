defmodule Domain.Relays do
  import Ecto.Changeset
  alias Domain.{Repo, Auth, Geo, Safe, Presence}
  alias Domain.Tokens
  alias Domain.Relays.Relay
  alias Domain.RelayGroup

  def send_metrics do
    Presence.Relays.send_metrics()
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    result =
      __MODULE__.DB.all_groups()
      |> __MODULE__.DB.by_id(id)
      |> Safe.scoped(subject)
      |> Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      group -> {:ok, group}
    end
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    __MODULE__.DB.all_groups()
    |> Safe.scoped(subject)
    |> Safe.list(__MODULE__.DB, opts)
  end

  def new_group(attrs \\ %{}) do
    change_group(%RelayGroup{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    changeset =
      %RelayGroup{account: subject.account}
      |> cast(attrs, ~w[name]a)
      |> put_change(:account_id, subject.account.id)

    Safe.scoped(changeset, subject)
    |> Safe.insert()
  end

  def create_global_group(attrs) do
    %RelayGroup{}
    |> cast(attrs, ~w[name]a)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def change_group(%RelayGroup{} = group, attrs \\ %{}) do
    group
    |> Safe.preload(:account)
    |> cast(attrs, ~w[name]a)
  end

  def update_group(group, attrs \\ %{}, subject)

  def update_group(%RelayGroup{account_id: nil}, _attrs, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def update_group(%RelayGroup{} = group, attrs, %Auth.Subject{} = subject) do
    changeset =
      group
      |> Safe.preload(:account)
      |> cast(attrs, ~w[name]a)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def delete_group(%RelayGroup{account_id: nil}, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def delete_group(%RelayGroup{} = group, %Auth.Subject{} = subject) do
    Safe.scoped(group, subject)
    |> Safe.delete()
  end

  def create_token(%RelayGroup{account_id: nil} = group, attrs) do
    attrs =
      Map.merge(attrs, %{
        "type" => :relay_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "relay_group_id" => group.id
      })

    with {:ok, token} <- Tokens.create_token(attrs) do
      {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Tokens.encode_fragment!(token)}
    end
  end

  def create_token(
        %RelayGroup{account_id: account_id} = group,
        attrs,
        %Auth.Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :relay_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => group.account_id,
        "relay_group_id" => group.id
      })

    with {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Tokens.encode_fragment!(token)}
    end
  end

  def authenticate(encoded_token, %Auth.Context{} = context) when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         queryable = __MODULE__.DB.all_groups() |> __MODULE__.DB.by_id(token.relay_group_id),
         {:ok, group} <- Repo.fetch(queryable, RelayGroup, []) do
      {:ok, group, token}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  def fetch_relay_by_id(id, %Auth.Subject{} = subject) do
    result =
      Relay.Query.all()
      |> Relay.Query.by_id(id)
      |> Safe.scoped(subject)
      |> Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      relay -> {:ok, relay}
    end
  end

  def list_relays(%Auth.Subject{} = subject, opts \\ []) do
    Relay.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Relay.Query, opts)
  end

  @doc false
  def preload_relays_presence(relays) do
    Presence.Relays.preload_relays_presence(relays)
  end

  def all_connected_relays_for_account(account_id_or_account, except_ids \\ [])

  def all_connected_relays_for_account(%Domain.Account{} = account, except_ids) do
    all_connected_relays_for_account(account.id, except_ids)
  end

  def all_connected_relays_for_account(account_id, except_ids) do
    connected_global_relays = Presence.Relays.Global.list()
    connected_account_relays = Presence.Relays.Account.list(account_id)

    connected_relays = Map.merge(connected_global_relays, connected_account_relays)
    connected_relay_ids = Map.keys(connected_relays) -- except_ids

    relays =
      Relay.Query.all()
      |> Relay.Query.by_ids(connected_relay_ids)
      |> Relay.Query.global_or_by_account_id(account_id)
      # |> Relay.Query.by_last_seen_at_greater_than(5, "second", :ago)
      |> Relay.Query.prefer_global()
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(fn relay ->
        %{metas: metas} = Map.get(connected_relays, relay.id)

        %{secret: stamp_secret} =
          metas
          |> Enum.sort_by(& &1.online_at, :desc)
          |> List.first()

        %{relay | stamp_secret: stamp_secret}
      end)

    {:ok, relays}
  end

  # TODO: Relays
  # Revisit credential lifetime when https://github.com/firezone/firezone/issues/8222 is implemented
  def generate_username_and_password(%Relay{stamp_secret: stamp_secret}, public_key, expires_at)
      when is_binary(stamp_secret) do
    salt = generate_hash(public_key)
    expires_at = DateTime.to_unix(expires_at, :second)
    password = generate_hash("#{expires_at}:#{stamp_secret}:#{salt}")

    %{username: "#{expires_at}:#{salt}", password: password, expires_at: expires_at}
  end

  defp generate_hash(string) do
    :crypto.hash(:sha256, string)
    |> Base.encode64(padding: false)
  end

  def upsert_relay(%RelayGroup{} = group, attrs, %Auth.Context{} = context) do
    changeset = Relay.Changeset.upsert(group, attrs, context)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:relay, changeset,
      conflict_target: Relay.Changeset.upsert_conflict_target(group),
      on_conflict: Relay.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> Safe.transact()
    |> case do
      {:ok, %{relay: relay}} -> {:ok, relay}
      {:error, :relay, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  def delete_relay(%Relay{} = relay, %Auth.Subject{} = subject) do
    Safe.scoped(relay, subject)
    |> Safe.delete()
  end

  @doc """
  Selects 3 nearest relays to the given location and then picks one of them randomly.
  """
  def load_balance_relays({lat, lon}, relays) when is_nil(lat) or is_nil(lon) do
    relays
    |> Enum.shuffle()
    |> Enum.take(2)
  end

  def load_balance_relays({lat, lon}, relays) do
    relays
    # This allows to group relays that are running at the same location so
    # we are using at least 2 locations to build ICE candidates
    |> Enum.group_by(fn relay ->
      {relay.last_seen_remote_ip_location_lat, relay.last_seen_remote_ip_location_lon}
    end)
    |> Enum.map(fn
      {{nil, nil}, relay} ->
        {nil, relay}

      {{relay_lat, relay_lon}, relay} ->
        distance = Geo.distance({lat, lon}, {relay_lat, relay_lon})
        {distance, relay}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(2)
    |> Enum.map(&Enum.random(elem(&1, 1)))
  end

  # TODO: WAL
  # Refactor to use new conventions
  def connect_relay(%Relay{} = relay, secret, token_id) do
    with {:ok, _} <-
           Presence.track(
             self(),
             Presence.Relays.Group.topic(relay.group_id),
             relay.id,
             %{
               token_id: token_id
             }
           ),
         {:ok, _} <-
           track_relay_with_secret(relay, secret),
         {:ok, _} <-
           Presence.track(self(), "presences:relays:#{relay.id}", relay.id, %{}) do
      :ok = Domain.PubSub.Relay.subscribe(relay.id)
      :ok = Domain.PubSub.RelayGroup.subscribe(relay.group_id)
      :ok = Domain.PubSub.RelayAccount.subscribe(relay.account_id)
      :ok
    end
  end

  defp track_relay_with_secret(%Relay{account_id: nil} = relay, secret) do
    Presence.track(self(), Presence.Relays.Global.topic(), relay.id, %{
      online_at: System.system_time(:second),
      secret: secret
    })
  end

  defp track_relay_with_secret(%Relay{account_id: account_id} = relay, secret) do
    Presence.track(self(), Presence.Relays.Account.topic(account_id), relay.id, %{
      online_at: System.system_time(:second),
      secret: secret
    })
  end

  def subscribe_to_relay_presence(relay_or_id) do
    Presence.Relays.Relay.subscribe(get_relay_id(relay_or_id))
  end

  def unsubscribe_from_relay_presence(relay_or_id) do
    Presence.Relays.Relay.unsubscribe(get_relay_id(relay_or_id))
  end

  def subscribe_to_relays_presence_in_account(account_or_id) do
    Presence.Relays.Global.subscribe()
    Presence.Relays.Account.subscribe(get_account_id(account_or_id))
  end

  def unsubscribe_from_relays_presence_in_account(account_or_id) do
    Presence.Relays.Global.unsubscribe()
    Presence.Relays.Account.unsubscribe(get_account_id(account_or_id))
  end

  def subscribe_to_relays_presence_in_group(group_or_id) do
    Presence.Relays.Group.subscribe(get_group_id(group_or_id))
  end

  def unsubscribe_from_relays_presence_in_group(group_or_id) do
    Presence.Relays.Group.unsubscribe(get_group_id(group_or_id))
  end

  defp get_relay_id(%Relay{id: id}), do: id
  defp get_relay_id(relay_id) when is_binary(relay_id), do: relay_id

  defp get_account_id(%Domain.Account{id: id}), do: id
  defp get_account_id(account_id) when is_binary(account_id), do: account_id

  defp get_group_id(%RelayGroup{id: id}), do: id
  defp get_group_id(group_id) when is_binary(group_id), do: group_id

  def broadcast_to_relay(relay_or_id, payload) do
    Domain.PubSub.Relay.broadcast(get_relay_id(relay_or_id), payload)
  end

  defp broadcast_to_relays_in_account(account_or_id, payload) do
    Domain.PubSub.RelayAccount.broadcast(get_account_id(account_or_id), payload)
  end

  defp broadcast_to_relays_in_group(group_or_id, payload) do
    Domain.PubSub.RelayGroup.broadcast(get_group_id(group_or_id), payload)
  end

  def disconnect_relay(relay_or_id) do
    broadcast_to_relay(relay_or_id, "disconnect")
  end

  def disconnect_relays_in_group(group_or_id) do
    broadcast_to_relays_in_group(group_or_id, "disconnect")
  end

  def disconnect_relays_in_account(account_or_id) do
    broadcast_to_relays_in_account(account_or_id, "disconnect")
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.RelayGroup

    def all_groups do
      from(groups in RelayGroup, as: :groups)
    end

    def by_id(queryable, id) do
      where(queryable, [groups: groups], groups.id == ^id)
    end

    def by_account_id(queryable, account_id) do
      where(queryable, [groups: groups], groups.account_id == ^account_id)
    end

    def global(queryable) do
      where(queryable, [groups: groups], is_nil(groups.account_id))
    end

    def global_or_by_account_id(queryable, account_id) do
      where(
        queryable,
        [groups: groups],
        groups.account_id == ^account_id or is_nil(groups.account_id)
      )
    end

    # Pagination - implementing Query behavior
    def cursor_fields,
      do: [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]

    def preloads,
      do: [
        relays: Domain.Relays.Relay.Query.preloads()
      ]

    def filters, do: []
  end
end
