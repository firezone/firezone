defmodule Domain.Gateways do
  use Supervisor
  alias Domain.Accounts.Account
  alias Domain.{Repo, Auth, Geo, PubSub}
  alias Domain.{Accounts, Resources, Tokens, Billing}
  alias Domain.Gateways.{Authorizer, Gateway, Group, Presence}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def count_groups_for_account(%Accounts.Account{} = account) do
    Group.Query.not_deleted()
    |> Group.Query.by_account_id(account.id)
    |> Repo.aggregate(:count)
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
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

  def fetch_internet_group(%Accounts.Account{} = account) do
    Group.Query.not_deleted()
    |> Group.Query.by_managed_by(:system)
    |> Group.Query.by_account_id(account.id)
    |> Group.Query.by_name("Internet")
    |> Repo.fetch(Group.Query, [])
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Group.Query, opts)
    end
  end

  def all_groups!(%Auth.Subject{} = subject) do
    Group.Query.not_deleted()
    |> Group.Query.by_managed_by(:account)
    |> Authorizer.for_subject(subject)
    |> Repo.all()
  end

  def all_groups_for_account!(%Accounts.Account{} = account) do
    Group.Query.not_deleted()
    |> Group.Query.by_managed_by(:account)
    |> Group.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
         true <- Billing.can_create_gateway_groups?(subject.account) do
      subject.account
      |> Group.Changeset.create(attrs, subject)
      |> Repo.insert()
    else
      false -> {:error, :gateway_groups_limit_reached}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_group(%Accounts.Account{} = account, attrs) do
    account
    |> Group.Changeset.create(attrs)
    |> Repo.insert()
  end

  def create_internet_group(%Accounts.Account{} = account) do
    attrs = %{
      "name" => "Internet",
      "managed_by" => "system"
    }

    account
    |> Group.Changeset.create(attrs)
    |> Repo.insert()
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:account)
    |> Group.Changeset.update(attrs)
  end

  def update_group(%Group{managed_by: :account} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        Group.Query,
        with: fn group ->
          group
          |> Repo.preload(:account)
          |> Group.Changeset.update(attrs, subject)
        end
      )
      |> case do
        {:ok, group} ->
          :ok = broadcast_to_group(group, :updated)
          {:ok, group}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_group(%Group{managed_by: :account} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.not_deleted()
      |> Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Group.Query,
        with: fn group ->
          {:ok, _tokens} = Tokens.delete_tokens_for(group, subject)
          {:ok, _count} = Resources.delete_connections_for(group, subject)

          {_count, _} =
            Gateway.Query.not_deleted()
            |> Gateway.Query.by_group_id(group.id)
            |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

          Group.Changeset.delete(group)
        end,
        after_commit: &disconnect_gateways_in_group/1
      )
    end
  end

  def create_token(
        %Group{account_id: account_id} = group,
        attrs,
        %Auth.Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :gateway_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => group.account_id,
        "gateway_group_id" => group.id,
        "created_by_user_agent" => subject.context.user_agent,
        "created_by_remote_ip" => subject.context.remote_ip
      })

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
         {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Tokens.encode_fragment!(token)}
    end
  end

  def authenticate(encoded_token, %Auth.Context{} = context) when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         queryable = Group.Query.not_deleted() |> Group.Query.by_id(token.gateway_group_id),
         {:ok, group} <- Repo.fetch(queryable, Group.Query, []) do
      {:ok, group, token}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  def fetch_gateway_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_gateways_permission(),
         Authorizer.connect_gateways_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Gateway.Query.all()
      |> Gateway.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Gateway.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_gateway_by_id!(id, opts \\ []) do
    Gateway.Query.not_deleted()
    |> Gateway.Query.by_id(id)
    |> Repo.fetch!(Gateway.Query, opts)
  end

  def list_gateways(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Gateway.Query, opts)
    end
  end

  def all_gateways_for_account!(%Account{} = account, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Gateway.Query.not_deleted()
    |> Gateway.Query.by_account_id(account.id)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc false
  def preload_gateways_presence([gateway]) do
    gateway.account_id
    |> account_gateways_presence_topic()
    |> Presence.get_by_key(gateway.id)
    |> case do
      [] -> %{gateway | online?: false}
      %{metas: [_ | _]} -> %{gateway | online?: true}
    end
    |> List.wrap()
  end

  def preload_gateways_presence(gateways) do
    # we fetch list of account gateways for every account_id present in the gateways list
    connected_gateways =
      gateways
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn account_id, acc ->
        connected_gateways = account_id |> account_gateways_presence_topic() |> Presence.list()
        Map.merge(acc, connected_gateways)
      end)

    Enum.map(gateways, fn gateway ->
      %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
    end)
  end

  def all_online_gateway_ids_by_group_id!(group_id) do
    group_id
    |> group_gateways_presence_topic()
    |> Presence.list()
    |> Map.keys()
  end

  def all_connected_gateways_for_resource(
        %Resources.Resource{} = resource,
        %Auth.Subject{} = subject,
        opts \\ []
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.connect_gateways_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      connected_gateway_ids =
        resource.account_id
        |> account_gateways_presence_topic()
        |> Presence.list()
        |> Map.keys()

      gateways =
        Gateway.Query.not_deleted()
        # TODO: This will create a pretty large query to send to Postgres,
        # we probably want to load connected resources once when gateway connects,
        # and persist them in the memory not to query DB every time with a
        # `WHERE ... IN (...)`.
        |> Gateway.Query.by_ids(connected_gateway_ids)
        |> Gateway.Query.by_account_id(resource.account_id)
        |> Gateway.Query.by_resource_id(resource.id)
        |> Repo.all()
        |> Repo.preload(preload)

      {:ok, gateways}
    end
  end

  def gateway_can_connect_to_resource?(%Gateway{} = gateway, %Resources.Resource{} = resource) do
    connected_gateway_ids =
      resource.account_id
      |> account_gateways_presence_topic()
      |> Presence.list()
      |> Map.keys()

    cond do
      gateway.id not in connected_gateway_ids ->
        false

      not Resources.connected?(resource, gateway) ->
        false

      true ->
        true
    end
  end

  def change_gateway(%Gateway{} = gateway, attrs \\ %{}) do
    Gateway.Changeset.update(gateway, attrs)
  end

  def upsert_gateway(%Group{} = group, %Tokens.Token{} = token, attrs, %Auth.Context{} = context) do
    changeset = Gateway.Changeset.upsert(group, token, attrs, context)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:gateway, changeset,
      conflict_target: Gateway.Changeset.upsert_conflict_target(),
      on_conflict: Gateway.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> resolve_address_multi(:ipv4)
    |> resolve_address_multi(:ipv6)
    |> Ecto.Multi.update(:gateway_with_address, fn
      %{gateway: %Gateway{} = gateway, ipv4: ipv4, ipv6: ipv6} ->
        Gateway.Changeset.finalize_upsert(gateway, ipv4, ipv6)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{gateway_with_address: gateway}} -> {:ok, gateway}
      {:error, :gateway, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{gateway: %Gateway{} = gateway} ->
      if address = Map.get(gateway, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(gateway.account_id, type)}
      end
    end)
  end

  def update_gateway(%Gateway{} = gateway, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.not_deleted()
      |> Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Gateway.Query,
        with: &Gateway.Changeset.update(&1, attrs),
        preload: [:online?]
      )
    end
  end

  def delete_gateway(%Gateway{} = gateway, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.not_deleted()
      |> Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Gateway.Query,
        with: &Gateway.Changeset.delete/1,
        after_commit: &disconnect_gateway/1,
        preload: [:online?]
      )
    end
  end

  def load_balance_gateways({_lat, _lon}, []) do
    nil
  end

  def load_balance_gateways({lat, lon}, gateways) when is_nil(lat) or is_nil(lon) do
    Enum.random(gateways)
  end

  def load_balance_gateways({lat, lon}, gateways) do
    gateways
    # Group gateways by their geographical location
    |> Enum.group_by(fn gateway ->
      {gateway.last_seen_remote_ip_location_lat, gateway.last_seen_remote_ip_location_lon}
    end)
    # Replace the location with the approximate distance to the client
    |> Enum.map(fn
      {{gateway_lat, gateway_lon}, gateway} when is_nil(gateway_lat) or is_nil(gateway_lon) ->
        {nil, gateway}

      {{gateway_lat, gateway_lon}, gateway} ->
        distance = Geo.distance({lat, lon}, {gateway_lat, gateway_lon})
        {distance, gateway}
    end)
    # Sort by the distance to the client
    |> Enum.sort_by(&elem(&1, 0))
    # Select all gateways in the nearest location
    |> List.first()
    |> elem(1)
    # Group nearest gateways by their version and only leave the one running the greatest one
    |> Enum.group_by(fn gateway -> gateway.last_seen_version end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.at(0)
    |> elem(1)
    # From all nearest gateways of the latest version, select the one at random
    |> Enum.random()
  end

  def load_balance_gateways({lat, lon}, gateways, preferred_gateway_ids) do
    gateways
    |> Enum.filter(&(&1.id in preferred_gateway_ids))
    |> case do
      [] -> load_balance_gateways({lat, lon}, gateways)
      preferred_gateways -> load_balance_gateways({lat, lon}, preferred_gateways)
    end
  end

  def connect_gateway(%Gateway{} = gateway) do
    with {:ok, _} <-
           Presence.track(
             self(),
             group_gateways_presence_topic(gateway.group_id),
             gateway.id,
             %{}
           ),
         {:ok, _} <-
           Presence.track(
             self(),
             account_gateways_presence_topic(gateway.account_id),
             gateway.id,
             %{
               online_at: System.system_time(:second)
             }
           ) do
      :ok = PubSub.subscribe(gateway_topic(gateway))
      :ok = PubSub.subscribe(group_gateways_topic(gateway.group_id))
      :ok = PubSub.subscribe(account_gateways_topic(gateway.account_id))
      :ok
    end
  end

  def gateway_outdated?(gateway) do
    latest_release = Domain.ComponentVersions.gateway_version()

    case Version.compare(gateway.last_seen_version, latest_release) do
      :lt -> true
      _ -> false
    end
  end

  ### Presence

  def account_gateways_presence_topic(account_or_id),
    do: "presences:#{account_gateways_topic(account_or_id)}"

  defp group_gateways_presence_topic(group_or_id),
    do: "presences:#{group_gateways_topic(group_or_id)}"

  ### PubSub

  defp gateway_topic(%Gateway{} = gateway), do: gateway_topic(gateway.id)
  defp gateway_topic(gateway_id), do: "gateways:#{gateway_id}"

  defp account_gateways_topic(%Accounts.Account{} = account),
    do: account_gateways_topic(account.id)

  defp account_gateways_topic(account_id),
    do: "account_gateways:#{account_id}"

  defp group_gateways_topic(%Group{} = group), do: group_gateways_topic(group.id)
  defp group_gateways_topic(group_id), do: "group_gateways:#{group_id}"

  defp group_topic(%Group{} = group), do: group_topic(group.id)
  defp group_topic(group_id), do: "group:#{group_id}"

  def subscribe_to_group_updates(group_or_id) do
    group_or_id
    |> group_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe_from_group_updates(group_or_id) do
    group_or_id
    |> group_topic()
    |> PubSub.unsubscribe()
  end

  def subscribe_to_gateways_presence_in_account(%Accounts.Account{} = account) do
    account
    |> account_gateways_presence_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe_from_gateways_presence_in_account(%Accounts.Account{} = account) do
    account
    |> account_gateways_presence_topic()
    |> PubSub.unsubscribe()
  end

  def subscribe_to_gateways_presence_in_group(group_or_id) do
    group_or_id
    |> group_gateways_presence_topic()
    |> PubSub.subscribe()
  end

  def unsubscribe_from_gateways_presence_in_group(group_or_id) do
    group_or_id
    |> group_gateways_presence_topic()
    |> PubSub.unsubscribe()
  end

  def broadcast_to_group(group_or_id, payload) do
    group_or_id
    |> group_topic()
    |> PubSub.broadcast(payload)
  end

  def broadcast_to_gateway(gateway_or_id, payload) do
    gateway_or_id
    |> gateway_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_gateways_in_group(group_or_id, payload) do
    group_or_id
    |> group_gateways_topic()
    |> PubSub.broadcast(payload)
  end

  defp broadcast_to_gateways_in_account(account_or_id, payload) do
    account_or_id
    |> account_gateways_topic()
    |> PubSub.broadcast(payload)
  end

  def disconnect_gateway(gateway_or_id) do
    broadcast_to_gateway(gateway_or_id, "disconnect")
  end

  def disconnect_gateways_in_group(group_or_id) do
    broadcast_to_gateways_in_group(group_or_id, "disconnect")
  end

  def disconnect_gateways_in_account(account_or_id) do
    broadcast_to_gateways_in_account(account_or_id, "disconnect")
  end
end
