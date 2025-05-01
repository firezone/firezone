defmodule Domain.Relays do
  use Supervisor
  alias Domain.{Repo, Auth, Geo, PubSub}
  alias Domain.{Accounts, Tokens}
  alias Domain.Relays.{Authorizer, Relay, Group, Presence}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def send_metrics do
    count = global_groups_presence_topic() |> Presence.list() |> Enum.count()

    :telemetry.execute([:domain, :relays], %{
      online_relays_count: count
    })
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Repo.valid_uuid?(id) do
      Group.Query.all()
      |> Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Group.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Group.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Group.Query, opts)
    end
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      subject.account
      |> Group.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_global_group(attrs) do
    Group.Changeset.create(attrs)
    |> Repo.insert()
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:account)
    |> Group.Changeset.update(attrs)
  end

  def update_group(group, attrs \\ %{}, subject)

  def update_group(%Group{account_id: nil}, _attrs, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      group
      |> Repo.preload(:account)
      |> Group.Changeset.update(attrs, subject)
      |> Repo.update()
    end
  end

  def delete_group(%Group{account_id: nil}, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Authorizer.ensure_has_access_to(group, subject) do
      Repo.delete(group, stale_error_field: false)
    end
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` column is removed from DB
  def soft_delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Group.Query.by_account_id(subject.account.id)
      |> Repo.fetch_and_update(Group.Query,
        with: fn group ->
          {:ok, _tokens} = Tokens.soft_delete_tokens_for(group, subject)

          {_count, _} =
            Relay.Query.not_deleted()
            |> Relay.Query.by_group_id(group.id)
            |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

          Group.Changeset.delete(group)
        end,
        # TODO: Remove self-hosted relays
        after_commit: &disconnect_relays_in_group/1
      )
    end
  end

  def create_token(%Group{account_id: nil} = group, attrs) do
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
        %Group{account_id: account_id} = group,
        attrs,
        %Auth.Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :relay_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => group.account_id,
        "relay_group_id" => group.id,
        "created_by_user_agent" => subject.context.user_agent,
        "created_by_remote_ip" => subject.context.remote_ip
      })

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Tokens.encode_fragment!(token)}
    end
  end

  def authenticate(encoded_token, %Auth.Context{} = context) when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         queryable = Group.Query.not_deleted() |> Group.Query.by_id(token.relay_group_id),
         {:ok, group} <- Repo.fetch(queryable, Group.Query, []) do
      {:ok, group, token}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  def fetch_relay_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Repo.valid_uuid?(id) do
      Relay.Query.all()
      |> Relay.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Relay.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_relay_by_id!(id, opts \\ []) do
    Relay.Query.not_deleted()
    |> Relay.Query.by_id(id)
    |> Repo.fetch!(Relay.Query, opts)
  end

  def list_relays(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Relay.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Relay.Query, opts)
    end
  end

  @doc false
  def preload_relays_presence([%{account_id: nil} = relay]) do
    global_groups_presence_topic()
    |> Presence.get_by_key(relay.id)
    |> case do
      [] -> %{relay | online?: false}
      %{metas: [_ | _]} -> %{relay | online?: true}
    end
    |> List.wrap()
  end

  def preload_relays_presence([relay]) do
    relay.account_id
    |> account_presence_topic()
    |> Presence.get_by_key(relay.id)
    |> case do
      [] -> %{relay | online?: false}
      %{metas: [_ | _]} -> %{relay | online?: true}
    end
    |> List.wrap()
  end

  def preload_relays_presence(relays) do
    # if there are relays without account_id, we need to fetch global relays
    connected_global_relays =
      if Enum.any?(relays, &is_nil(&1.account_id)) do
        global_groups_presence_topic() |> Presence.list()
      else
        %{}
      end

    # we fetch list of account relays for every account_id present in the relays list
    connected_relays =
      relays
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn account_id, acc ->
        connected_relays = account_id |> account_presence_topic() |> Presence.list()
        Map.merge(acc, connected_relays)
      end)

    all_connected_relays = Map.merge(connected_relays, connected_global_relays)

    Enum.map(relays, fn relay ->
      %{relay | online?: Map.has_key?(all_connected_relays, relay.id)}
    end)
  end

  def all_connected_relays_for_account(account_id_or_account, except_ids \\ [])

  def all_connected_relays_for_account(%Accounts.Account{} = account, except_ids) do
    all_connected_relays_for_account(account.id, except_ids)
  end

  def all_connected_relays_for_account(account_id, except_ids) do
    connected_global_relays =
      global_groups_presence_topic()
      |> Presence.list()

    connected_account_relays =
      account_presence_topic(account_id)
      |> Presence.list()

    connected_relays = Map.merge(connected_global_relays, connected_account_relays)
    connected_relay_ids = Map.keys(connected_relays) -- except_ids

    relays =
      Relay.Query.not_deleted()
      |> Relay.Query.by_ids(connected_relay_ids)
      |> Relay.Query.global_or_by_account_id(account_id)
      # |> Relay.Query.by_last_seen_at_greater_than(5, "second", :ago)
      |> Relay.Query.prefer_global()
      |> Repo.all()
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

  def upsert_relay(%Group{} = group, %Tokens.Token{} = token, attrs, %Auth.Context{} = context) do
    changeset = Relay.Changeset.upsert(group, token, attrs, context)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:relay, changeset,
      conflict_target: Relay.Changeset.upsert_conflict_target(group),
      on_conflict: Relay.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{relay: relay}} -> {:ok, relay}
      {:error, :relay, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  def delete_relay(%Relay{} = relay, %Auth.Subject{} = subject) do
    with :ok <- Authorizer.ensure_has_access_to(relay, subject) do
      Repo.delete(relay, stale_error_field: false)
    end
  end

  # TODO: HARD-DELETE - Remove after `deleted_at` is removed from DB
  def soft_delete_relay(%Relay{} = relay, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Relay.Query.not_deleted()
      |> Relay.Query.by_id(relay.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Relay.Query,
        with: &Relay.Changeset.delete/1,
        # TODO: Remove self-hosted relays
        after_commit: &disconnect_relay/1
      )
    end
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

  # TODO: Refactor to use new conventions
  def connect_relay(%Relay{} = relay, secret) do
    with {:ok, _} <-
           Presence.track(self(), group_presence_topic(relay.group_id), relay.id, %{}),
         {:ok, _} <-
           Presence.track(self(), account_or_global_presence_topic(relay), relay.id, %{
             online_at: System.system_time(:second),
             secret: secret
           }),
         {:ok, _} <- Presence.track(self(), presence_topic(relay), relay.id, %{}) do
      :ok = PubSub.subscribe(relay_topic(relay))
      :ok = PubSub.subscribe(group_topic(relay.group_id))
      :ok = PubSub.subscribe(account_topic(relay.account_id))
      :ok
    end
  end

  ### Presence

  # TODO: Move these to Presence module

  defp presence_topic(relay_or_id),
    do: "presences:#{relay_topic(relay_or_id)}"

  defp account_or_global_presence_topic(%Relay{account_id: nil}),
    do: global_groups_presence_topic()

  defp account_or_global_presence_topic(%Relay{account_id: account_id}),
    do: account_presence_topic(account_id)

  def global_groups_presence_topic,
    do: "presences:#{global_groups_topic()}"

  def account_presence_topic(account_or_id),
    do: "presences:#{account_topic(account_or_id)}"

  defp group_presence_topic(group_or_id),
    do: "presences:#{group_topic(group_or_id)}"

  ### PubSub

  # TODO: Move these to PubSub module

  defp relay_topic(%Relay{} = relay), do: relay_topic(relay.id)
  defp relay_topic(relay_id), do: "relays:#{relay_id}"

  defp global_groups_topic, do: "global_relays"

  defp account_topic(%Accounts.Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "account_relays:#{account_id}"

  defp group_topic(%Group{} = group), do: group_topic(group.id)
  defp group_topic(group_id), do: "group_relays:#{group_id}"

  def subscribe_to_relay_presence(relay_or_id) do
    PubSub.subscribe(presence_topic(relay_or_id))
  end

  def unsubscribe_from_relay_presence(relay_or_id) do
    PubSub.unsubscribe(presence_topic(relay_or_id))
  end

  def subscribe_to_relays_presence_in_account(account_or_id) do
    PubSub.subscribe(global_groups_presence_topic())
    PubSub.subscribe(account_presence_topic(account_or_id))
  end

  def unsubscribe_from_relays_presence_in_account(account_or_id) do
    PubSub.unsubscribe(global_groups_presence_topic())
    PubSub.unsubscribe(account_presence_topic(account_or_id))
  end

  def subscribe_to_relays_presence_in_group(group_or_id) do
    group_or_id
    |> group_presence_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe_from_relays_presence_in_group(group_or_id) do
    group_or_id
    |> group_presence_topic()
    |> PubSub.unsubscribe()
  end

  def broadcast_to_relay(relay_or_id, payload) do
    relay_or_id
    |> relay_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_relays_in_account(account_or_id, payload) do
    account_or_id
    |> account_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_relays_in_group(group_or_id, payload) do
    group_or_id
    |> group_topic()
    |> PubSub.broadcast(payload)
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
end
