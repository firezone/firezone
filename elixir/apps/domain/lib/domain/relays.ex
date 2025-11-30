defmodule Domain.Relays do
  import Ecto.Changeset
  import Ecto.Query
  import Domain.Repo.Changeset
  alias Domain.{Repo, Auth, Geo, Safe, Version}
  alias Domain.Tokens
  alias Domain.Relay
  alias Domain.RelayGroup

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
      from(relays in Relay, as: :relays)
      |> where([relays: relays], relays.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()

    case result do
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      relay -> {:ok, relay}
    end
  end

  def list_relays(%Auth.Subject{} = subject, opts \\ []) do
    from(relays in Relay, as: :relays)
    |> Safe.scoped(subject)
    |> Safe.list(__MODULE__.DB, opts)
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
    changeset = upsert_changeset(group, attrs, context)

    conflict_target = upsert_conflict_target(group)
    on_conflict = upsert_on_conflict()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:relay, changeset,
      conflict_target: conflict_target,
      on_conflict: on_conflict,
      returning: true
    )
    |> Safe.transact()
    |> case do
      {:ok, %{relay: relay}} -> {:ok, relay}
      {:error, :relay, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  defp upsert_changeset(%RelayGroup{} = group, attrs, %Auth.Context{} = context) do
    upsert_fields = ~w[ipv4 ipv6 port name
                       last_seen_user_agent
                       last_seen_remote_ip
                       last_seen_remote_ip_location_region
                       last_seen_remote_ip_location_city
                       last_seen_remote_ip_location_lat
                       last_seen_remote_ip_location_lon]a

    %Relay{}
    |> cast(attrs, upsert_fields)
    |> validate_required_one_of(~w[ipv4 ipv6]a)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> unique_constraint(:ipv4, name: :relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :relays_unique_address_index)
    |> unique_constraint(:port, name: :relays_unique_address_index)
    |> unique_constraint(:ipv4, name: :global_relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :global_relays_unique_address_index)
    |> unique_constraint(:port, name: :global_relays_unique_address_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, context.remote_ip)
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_relay_version()
    |> put_change(:account_id, group.account_id)
    |> put_change(:group_id, group.id)
  end

  defp put_relay_version(changeset) do
    with {_data_or_changes, user_agent} when not is_nil(user_agent) <-
           fetch_field(changeset, :last_seen_user_agent),
         {:ok, version} <- Version.fetch_version(user_agent) do
      put_change(changeset, :last_seen_version, version)
    else
      {:error, :invalid_user_agent} -> add_error(changeset, :last_seen_user_agent, "is invalid")
      _ -> changeset
    end
  end

  defp upsert_conflict_target(%{account_id: nil}) do
    {:unsafe_fragment, ~s/(COALESCE(ipv4, ipv6), port) WHERE account_id IS NULL/}
  end

  defp upsert_conflict_target(%{account_id: _account_id}) do
    {:unsafe_fragment, ~s/(account_id, COALESCE(ipv4, ipv6), port) WHERE account_id IS NOT NULL/}
  end

  defp upsert_on_conflict do
    conflict_replace_fields = ~w[ipv4 ipv6 port name
                                 last_seen_user_agent
                                 last_seen_remote_ip
                                 last_seen_remote_ip_location_region
                                 last_seen_remote_ip_location_city
                                 last_seen_remote_ip_location_lat
                                 last_seen_remote_ip_location_lon
                                 last_seen_version
                                 last_seen_at
                                 updated_at]a
    {:replace, conflict_replace_fields}
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

    # Relay pagination functions - implementing Query behavior for relays
    def cursor_fields,
      do: [
        {:relays, :asc, :inserted_at},
        {:relays, :asc, :id}
      ]

    def preloads,
      do: [
        online?: &Domain.Presence.Relays.preload_relays_presence/1
      ]

    def filters,
      do: [
        %Domain.Repo.Filter{
          name: :relay_group_id,
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_group_id/2
        },
        %Domain.Repo.Filter{
          name: :ids,
          type: {:list, {:string, :uuid}},
          fun: &filter_by_ids/2
        }
      ]

    def filter_by_group_id(queryable, group_id) do
      {queryable, dynamic([relays: relays], relays.group_id == ^group_id)}
    end

    def filter_by_ids(queryable, ids) do
      {queryable, dynamic([relays: relays], relays.id in ^ids)}
    end
  end
end
