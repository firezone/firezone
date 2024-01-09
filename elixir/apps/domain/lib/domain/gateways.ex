defmodule Domain.Gateways do
  use Supervisor
  alias Domain.{Repo, Auth, Validator, Geo}
  alias Domain.{Accounts, Resources}
  alias Domain.Gateways.{Authorizer, Gateway, Group, Token, Presence}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch_group_by_id(id) do
    with true <- Validator.valid_uuid?(id) do
      Group.Query.by_id(id)
      |> Repo.fetch()
      |> case do
        {:ok, group} ->
          group =
            group
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

  def fetch_group_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
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
    if Ecto.assoc_loaded?(group.gateways) do
      connected_gateways = Presence.list("gateway_groups:#{group.id}")

      gateways =
        Enum.map(group.gateways, fn gateway ->
          %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
        end)

      %{group | gateways: gateways}
    else
      group
    end
  end

  defp maybe_preload_online_statuses([]), do: []

  defp maybe_preload_online_statuses([group | _] = groups) do
    connected_gateways = Presence.list("gateways:#{group.account_id}")

    if Ecto.assoc_loaded?(group.gateways) do
      Enum.map(groups, fn group ->
        gateways =
          Enum.map(group.gateways, fn gateway ->
            %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
          end)

        %{group | gateways: gateways}
      end)
    else
      groups
    end
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      subject.account
      |> Group.Changeset.create(attrs, subject)
      |> Repo.insert()
    end
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:account)
    |> Group.Changeset.update(attrs)
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      group
      |> Repo.preload(:account)
      |> Group.Changeset.update(attrs, subject)
      |> Repo.update()
    end
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn group ->
          :ok =
            Token.Query.by_group_id(group.id)
            |> Repo.all()
            |> Enum.each(fn token ->
              Token.Changeset.delete(token)
              |> Repo.update!()
            end)

          group
          |> Group.Changeset.delete()
        end
      )
    end
  end

  def use_token_by_id_and_secret(id, secret) do
    if Validator.valid_uuid?(id) do
      Token.Query.by_id(id)
      |> Repo.fetch_and_update(
        with: fn token ->
          if Domain.Crypto.equal?(:argon2, secret, token.hash) do
            Token.Changeset.use(token)
          else
            :not_found
          end
        end
      )
    else
      {:error, :not_found}
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
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Gateway.Query.all()
      |> Gateway.Query.by_id(id)
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

  def fetch_gateway_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Gateway.Query.by_id(id)
    |> Repo.one!()
    |> preload_online_status()
    |> Repo.preload(preload)
  end

  def list_gateways(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      {:ok, gateways} =
        Gateway.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      gateways =
        gateways
        |> Repo.preload(preload)
        |> preload_online_statuses(subject.account.id)

      {:ok, gateways}
    end
  end

  # TODO: make it function of a preload, so that we don't pull this data when we don't need to
  defp preload_online_status(%Gateway{} = gateway) do
    case Presence.get_by_key("gateways:#{gateway.account_id}", gateway.id) do
      [] -> %{gateway | online?: false}
      %{metas: [_ | _]} -> %{gateway | online?: true}
    end
  end

  defp preload_online_statuses(gateways, account_id) do
    connected_gateways = Presence.list("gateways:#{account_id}")

    Enum.map(gateways, fn gateway ->
      %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
    end)
  end

  # TODO: this should be replaced with a filter in list_gateways
  def list_gateways_for_group(%Group{} = group, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, gateways} =
        Gateway.Query.not_deleted()
        |> Gateway.Query.by_group_id(group.id)
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      gateways =
        gateways
        |> Repo.preload(preload)
        |> preload_online_statuses(subject.account.id)

      {:ok, gateways}
    end
  end

  # TODO: this should be replaced with a filter in list_gateways
  def list_connected_gateways_for_group(%Group{} = group, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      connected_gateways = Presence.list("gateway_groups:#{group.id}")
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      {:ok, gateways} =
        connected_gateways
        |> Map.keys()
        |> Gateway.Query.by_ids()
        |> Gateway.Query.by_group_id(group.id)
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      gateways =
        gateways
        |> Enum.map(&%{&1 | online?: true})
        |> Repo.preload(preload)

      {:ok, gateways}
    end
  end

  def list_connected_gateways_for_resource(%Resources.Resource{} = resource, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])
    connected_gateways = Presence.list("gateways:#{resource.account_id}")

    gateways =
      connected_gateways
      |> Map.keys()
      # XXX: This will create a pretty large query to send to Postgres,
      # we probably want to load connected resources once when gateway connects,
      # and persist them in the memory not to query DB every time with a
      # `WHERE ... IN (...)`.
      |> Gateway.Query.by_ids()
      |> Gateway.Query.by_account_id(resource.account_id)
      |> Gateway.Query.by_resource_id(resource.id)
      |> Repo.all()
      |> Repo.preload(preload)

    {:ok, gateways}
  end

  def gateway_can_connect_to_resource?(%Gateway{} = gateway, %Resources.Resource{} = resource) do
    connected_gateway_ids = Presence.list("gateways:#{resource.account_id}") |> Map.keys()

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

  def upsert_gateway(%Token{} = token, attrs) do
    changeset = Gateway.Changeset.upsert(token, attrs)

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
      Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Gateway.Changeset.update(&1, attrs))
      |> case do
        {:ok, gateway} ->
          {:ok, preload_online_status(gateway)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_gateway(%Gateway{} = gateway, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Gateway.Changeset.delete/1)
      |> case do
        {:ok, gateway} ->
          {:ok, preload_online_status(gateway)}

        {:error, reason} ->
          {:error, reason}
      end
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
    # This allows to group gateways that are running at the same location so
    # we are using at least 2 locations to build ICE candidates
    |> Enum.group_by(fn gateway ->
      {gateway.last_seen_remote_ip_location_lat, gateway.last_seen_remote_ip_location_lon}
    end)
    |> Enum.map(fn
      {{gateway_lat, gateway_lon}, gateway} when is_nil(gateway_lat) or is_nil(gateway_lon) ->
        {Geo.fetch_radius_of_earth_km!(), gateway}

      {{gateway_lat, gateway_lon}, gateway} ->
        distance = Geo.distance({lat, lon}, {gateway_lat, gateway_lon})
        {distance, gateway}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.at(0)
    |> elem(1)
    |> Enum.group_by(fn gateway -> gateway.last_seen_version end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.at(0)
    |> elem(1)
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

  def encode_token!(%Token{value: value} = token) when not is_nil(value) do
    body = {token.id, token.value}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt, body)
  end

  def authorize_gateway(encrypted_secret) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    with {:ok, {id, secret}} <-
           Plug.Crypto.verify(key_base, salt, encrypted_secret, max_age: :infinity),
         {:ok, token} <- use_token_by_id_and_secret(id, secret) do
      {:ok, token}
    else
      {:error, :invalid} -> {:error, :invalid_token}
      {:error, :not_found} -> {:error, :invalid_token}
    end
  end

  def connect_gateway(%Gateway{} = gateway) do
    meta = %{online_at: System.system_time(:second)}

    with {:ok, _} <- Presence.track(self(), "gateways:#{gateway.account_id}", gateway.id, meta) do
      {:ok, _} = Presence.track(self(), "gateway_groups:#{gateway.group_id}", gateway.id, %{})
      :ok
    end
  end

  def subscribe_for_gateways_presence_in_account(%Accounts.Account{} = account) do
    Phoenix.PubSub.subscribe(Domain.PubSub, "gateways:#{account.id}")
  end

  def subscribe_for_gateways_presence_in_group(%Group{} = group) do
    Phoenix.PubSub.subscribe(Domain.PubSub, "gateway_groups:#{group.id}")
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end

  # Finds the most strict routing strategy for a given list of gateway groups.
  def relay_strategy(gateway_groups) when is_list(gateway_groups) do
    strictness = [
      stun_only: 3,
      self_hosted: 2,
      managed: 1
    ]

    gateway_groups
    |> Enum.max_by(fn %{routing: routing} ->
      Keyword.fetch!(strictness, routing)
    end)
    |> relay_strategy_mapping()
  end

  defp relay_strategy_mapping(%Group{} = group) do
    case group.routing do
      :stun_only -> {:managed, :stun}
      :self_hosted -> {:self_hosted, :turn}
      :managed -> {:managed, :turn}
    end
  end
end
