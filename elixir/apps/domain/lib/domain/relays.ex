defmodule Domain.Relays do
  import Ecto.Changeset
  alias Domain.{Repo, Auth, Geo, Safe}
  alias Domain.Tokens
  alias Domain.Relays.Relay
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
