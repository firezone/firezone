defmodule Domain.Relays do
  use Supervisor
  alias Domain.{Repo, Auth, Validator, Geo, PubSub}
  alias Domain.{Accounts, Resources, Tokens}
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

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Group.Query.all()
      |> Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, group} ->
          group =
            group
            |> Repo.preload(preload)
            |> maybe_preload_online_status()

          {:ok, group}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, groups} =
        Group.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      groups =
        groups
        |> Repo.preload(preload)
        |> maybe_preload_online_statuses()

      {:ok, groups}
    end
  end

  # TODO: this is ugly!
  defp maybe_preload_online_status(group) do
    if Ecto.assoc_loaded?(group.relays) do
      connected_relays = group |> group_presence_topic() |> Presence.list()

      relays =
        Enum.map(group.relays, fn relay ->
          %{relay | online?: Map.has_key?(connected_relays, relay.id)}
        end)

      %{group | relays: relays}
    else
      group
    end
  end

  defp maybe_preload_online_statuses([]), do: []

  defp maybe_preload_online_statuses([group | _] = groups) do
    connected_global_relays = global_group_presence_topic() |> Presence.list()
    connected_relays = group.account_id |> account_presence_topic() |> Presence.list()

    if Ecto.assoc_loaded?(group.relays) do
      Enum.map(groups, fn group ->
        relays =
          Enum.map(group.relays, fn relay ->
            online? =
              Map.has_key?(connected_relays, relay.id) or
                Map.has_key?(connected_global_relays, relay.id)

            %{relay | online?: online?}
          end)

        %{group | relays: relays}
      end)
    else
      groups
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Group.Query.by_account_id(subject.account.id)
      |> Repo.fetch_and_update(
        with: fn group ->
          {:ok, _count} = Tokens.delete_tokens_for(group, subject)

          {_count, _} =
            Relay.Query.by_group_id(group.id)
            |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

          Group.Changeset.delete(group)
        end
      )
      |> case do
        {:ok, group} ->
          :ok = disconnect_relays_in_group(group)
          {:ok, group}

        {:error, changeset} ->
          {:error, changeset}
      end
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
      {:ok, Tokens.encode_fragment!(token)}
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
      {:ok, Tokens.encode_fragment!(token)}
    end
  end

  def authenticate(encoded_token, %Auth.Context{} = context) when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         queryable = Group.Query.by_id(token.relay_group_id),
         {:ok, group} <- Repo.fetch(queryable) do
      {:ok, group, token}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  def fetch_relay_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Relay.Query.all()
      |> Relay.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, gateway} ->
          gateway =
            gateway
            |> Repo.preload(preload)
            |> preload_online_status()

          {:ok, gateway}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_relay_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Relay.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
    |> preload_online_status()
  end

  def list_relays(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, relays} =
        Relay.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      relays =
        relays
        |> Repo.preload(preload)
        |> preload_online_statuses(subject.account.id)

      {:ok, relays}
    end
  end

  # TODO: make it function of a preload, so that we don't pull this data when we don't need to
  defp preload_online_status(%Relay{} = relay) do
    relay.account_id
    |> account_presence_topic()
    |> Presence.get_by_key(relay.id)
    |> case do
      [] -> %{relay | online?: false}
      %{metas: [_ | _]} -> %{relay | online?: true}
    end
  end

  defp preload_online_statuses(relays, account_id) do
    connected_global_relays = global_group_presence_topic() |> Presence.list()
    connected_relays = account_id |> account_presence_topic() |> Presence.list()

    Enum.map(relays, fn relay ->
      online? =
        Map.has_key?(connected_relays, relay.id) or
          Map.has_key?(connected_global_relays, relay.id)

      %{relay | online?: online?}
    end)
  end

  def list_connected_relays_for_resource(%Resources.Resource{} = _resource, :managed) do
    connected_relays = global_group_presence_topic() |> Presence.list()
    filter = &Relay.Query.public(&1)
    list_relays_for_resource(connected_relays, filter)
  end

  def list_connected_relays_for_resource(%Resources.Resource{} = resource, :self_hosted) do
    connected_relays = resource.account_id |> account_presence_topic() |> Presence.list()
    filter = &Relay.Query.by_account_id(&1, resource.account_id)
    list_relays_for_resource(connected_relays, filter)
  end

  defp list_relays_for_resource(connected_relays, filter) do
    relays =
      connected_relays
      |> Map.keys()
      |> Relay.Query.by_ids()
      |> filter.()
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

  def generate_username_and_password(%Relay{stamp_secret: stamp_secret}, %DateTime{} = expires_at)
      when is_binary(stamp_secret) do
    expires_at = DateTime.to_unix(expires_at, :second)
    salt = Domain.Crypto.random_token()
    password = generate_hash(expires_at, stamp_secret, salt)
    %{username: "#{expires_at}:#{salt}", password: password, expires_at: expires_at}
  end

  defp generate_hash(expires_at, stamp_secret, salt) do
    :crypto.hash(:sha256, "#{expires_at}:#{stamp_secret}:#{salt}")
    |> Base.encode64(padding: false)
  end

  def upsert_relay(%Group{} = group, attrs, %Auth.Context{} = context) do
    changeset = Relay.Changeset.upsert(group, attrs, context)

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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Relay.Query.by_id(relay.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Relay.Changeset.delete/1)
      |> case do
        {:ok, relay} ->
          :ok = disconnect_relay(relay)
          {:ok, relay}

        {:error, changeset} ->
          {:error, changeset}
      end
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
        {Geo.fetch_radius_of_earth_km!(), relay}

      {{relay_lat, relay_lon}, relay} ->
        distance = Geo.distance({lat, lon}, {relay_lat, relay_lon})
        {distance, relay}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(2)
    |> Enum.map(&Enum.random(elem(&1, 1)))
  end

  def connect_relay(%Relay{} = relay, secret) do
    with {:ok, _} <-
           Presence.track(self(), group_presence_topic(relay.group_id), relay.id, %{}),
         {:ok, _} <-
           Presence.track(self(), presence_topic(relay), relay.id, %{
             online_at: System.system_time(:second),
             secret: secret
           }) do
      :ok = PubSub.subscribe(relay_topic(relay))
      :ok = PubSub.subscribe(group_topic(relay.group_id))
      :ok = PubSub.subscribe(account_topic(relay.account_id))
      :ok
    end
  end

  ### Presence

  defp presence_topic(%Relay{account_id: nil}),
    do: global_group_presence_topic()

  defp presence_topic(%Relay{account_id: account_id}),
    do: account_presence_topic(account_id)

  def global_group_presence_topic,
    do: "presences:#{global_groups_topic()}}"

  def account_presence_topic(account_or_id),
    do: "presences:#{account_topic(account_or_id)}"

  defp group_presence_topic(group_or_id),
    do: "presences:#{group_topic(group_or_id)}"

  ### PubSub

  defp relay_topic(%Relay{} = relay), do: relay_topic(relay.id)
  defp relay_topic(relay_id), do: "relays:#{relay_id}"

  defp global_groups_topic, do: "global_relays"

  defp account_topic(%Accounts.Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "account_relays:#{account_id}"

  defp group_topic(%Group{} = group), do: group_topic(group.id)
  defp group_topic(group_id), do: "group_relays:#{group_id}"

  def subscribe_for_relays_presence_in_account(%Accounts.Account{} = account) do
    PubSub.subscribe(global_groups_topic())
    PubSub.subscribe(account_topic(account))
  end

  def subscribe_for_relays_presence_in_group(%Group{} = group) do
    PubSub.subscribe(group_topic(group))
  end

  def broadcast_to_relay(relay_or_id, payload) do
    relay_or_id
    |> relay_topic()
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
end
