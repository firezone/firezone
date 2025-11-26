defmodule Domain.Gateways do
  use Supervisor
  alias Domain.Accounts.Account
  alias Domain.{Repo, Auth, Geo, Safe}
  alias Domain.{Accounts, Cache, Clients, Resources, Tokens, Billing}
  alias Domain.Gateways.{Gateway, Group, Presence}
  require Logger

  require Logger

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
    Group.Query.all()
    |> Group.Query.by_account_id(account.id)
    |> Group.Query.by_managed_by(:account)
    |> Safe.unscoped()
    |> Safe.aggregate(:count)
  end

  def fetch_gateway_by_id(id) do
    Gateway.Query.all()
    |> Gateway.Query.by_id(id)
    |> Repo.fetch(Gateway.Query, [])
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Group.Query.all()
        |> Group.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_internet_group(%Accounts.Account{} = account) do
    Group.Query.all()
    |> Group.Query.by_managed_by(:system)
    |> Group.Query.by_account_id(account.id)
    |> Group.Query.by_name("Internet")
    |> Repo.fetch(Group.Query, [])
  end

  def list_groups(%Auth.Subject{} = subject, opts \\ []) do
    Group.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Group.Query, opts)
  end

  def all_groups!(%Auth.Subject{} = subject) do
    Group.Query.all()
    |> Group.Query.by_managed_by(:account)
    |> Safe.scoped(subject)
    |> Safe.all()
    |> case do
      {:error, :unauthorized} -> []
      groups -> groups
    end
  end

  def all_groups_for_account!(%Accounts.Account{} = account) do
    Group.Query.all()
    |> Group.Query.by_managed_by(:account)
    |> Group.Query.by_account_id(account.id)
    |> Safe.unscoped()
    |> Safe.all()
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with true <- Billing.can_create_gateway_groups?(subject.account) do
      changeset =
        subject.account
        |> Group.Changeset.create(attrs, subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    else
      false -> {:error, :gateway_groups_limit_reached}
    end
  end

  def create_group(%Accounts.Account{} = account, attrs) do
    account
    |> Group.Changeset.create(attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def create_internet_group(%Accounts.Account{} = account) do
    attrs = %{
      "name" => "Internet",
      "managed_by" => "system"
    }

    account
    |> Group.Changeset.create(attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Safe.preload(:account)
    |> Group.Changeset.update(attrs)
  end

  def update_group(%Group{managed_by: :account} = group, attrs, %Auth.Subject{} = subject) do
    changeset =
      group
      |> Safe.preload(:account)
      |> Group.Changeset.update(attrs, subject)

    Safe.scoped(changeset, subject)
    |> Safe.update()
  end

  def delete_group(%Group{managed_by: :account} = group, %Auth.Subject{} = subject) do
    Safe.scoped(group, subject)
    |> Safe.delete()
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
        "gateway_group_id" => group.id
      })

    with {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, %{token | secret_nonce: nil, secret_fragment: nil}, Domain.Crypto.encode_token_fragment!(token)}
    end
  end

  def authenticate(encoded_token, %Auth.Context{} = context) when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         queryable = Group.Query.all() |> Group.Query.by_id(token.gateway_group_id),
         {:ok, group} <- Repo.fetch(queryable, Group.Query, []) do
      {:ok, group, token}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  def fetch_gateway_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Gateway.Query.all()
        |> Gateway.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_gateway_by_id!(id, opts \\ []) do
    Gateway.Query.all()
    |> Gateway.Query.by_id(id)
    |> Repo.fetch!(Gateway.Query, opts)
  end

  def list_gateways(%Auth.Subject{} = subject, opts \\ []) do
    Gateway.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Gateway.Query, opts)
  end

  def all_gateways_for_account!(%Account{} = account, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Gateway.Query.all()
    |> Gateway.Query.by_account_id(account.id)
    |> Safe.unscoped()
    |> Safe.all()
    |> Safe.preload(preload)
  end

  @doc false
  def preload_gateways_presence([gateway]) do
    Presence.Account.get(gateway.account_id, gateway.id)
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
        connected_gateways = Presence.Account.list(account_id)

        Map.merge(acc, connected_gateways)
      end)

    Enum.map(gateways, fn gateway ->
      %{gateway | online?: Map.has_key?(connected_gateways, gateway.id)}
    end)
  end

  def all_online_gateway_ids_by_group_id!(group_id) do
    Presence.Group.list(group_id)
    |> Map.keys()
  end

  def all_compatible_gateways_for_client_and_resource(
        %Clients.Client{} = client,
        %Cache.Cacheable.Resource{} = resource,
        %Auth.Subject{} = subject
      ) do
    resource_id = Ecto.UUID.load!(resource.id)

    connected_gateway_ids =
      Presence.Account.list(subject.account.id)
      |> Map.keys()

    gateways =
      Gateway.Query.all()
      |> Gateway.Query.by_ids(connected_gateway_ids)
      |> Gateway.Query.by_resource_id(resource_id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> []
        gateways -> filter_compatible_gateways(gateways, resource, client.last_seen_version)
      end

    {:ok, gateways}
  end

  def change_gateway(%Gateway{} = gateway, attrs \\ %{}) do
    Gateway.Changeset.update(gateway, attrs)
  end

  def upsert_gateway(%Group{} = group, attrs, %Auth.Context{} = context) do
    changeset = Gateway.Changeset.upsert(group, attrs, context)

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
    |> Safe.transact()
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
    changeset = Gateway.Changeset.update(gateway, attrs)

    case Safe.scoped(changeset, subject) |> Safe.update() do
      {:ok, updated_gateway} ->
        {:ok, preload_gateways_presence([updated_gateway]) |> List.first()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_gateway(%Gateway{} = gateway, %Auth.Subject{} = subject) do
    case Safe.scoped(gateway, subject) |> Safe.delete() do
      {:ok, deleted_gateway} ->
        {:ok, preload_gateways_presence([deleted_gateway]) |> List.first()}

      {:error, reason} ->
        {:error, reason}
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

  def gateway_outdated?(gateway) do
    latest_release = Domain.ComponentVersions.gateway_version()

    case Version.compare(gateway.last_seen_version, latest_release) do
      :lt -> true
      _ -> false
    end
  end

  # Filters gateways by the resource type, gateway version, and client version.
  # We support gateways running in one less minor and one greater minor version than the client.
  # So 1.2.x clients are compatible with 1.1.x and 1.3.x gateways, but not with 1.0.x or 1.4.x.
  # The internet resource requires gateway 1.3.0 or greater.
  defp filter_compatible_gateways(gateways, resource, client_version) do
    case Version.parse(client_version) do
      {:ok, version} ->
        gateways
        |> Enum.filter(fn gateway ->
          case Version.parse(gateway.last_seen_version) do
            {:ok, gateway_version} ->
              Version.match?(gateway_version, ">= #{version.major}.#{version.minor - 1}.0") and
                Version.match?(gateway_version, "< #{version.major}.#{version.minor + 2}.0") and
                not is_nil(
                  Resources.adapt_resource_for_version(resource, gateway.last_seen_version)
                )

            _ ->
              Logger.warning("Unable to parse gateway version: #{gateway.last_seen_version}")

              false
          end
        end)

      :error ->
        Logger.warning("Unable to parse client version: #{client_version}")

        []
    end
  end
end
