defmodule Portal.Cache.Client.Authorizations do
  @moduledoc """
    This cache is used in the client channel processes to maintain a materialized view of inbound
    policy_authorizations — entries where the channel's client is the `receiving_device_id` of a
    policy_authorization. It mirrors `Portal.Cache.Gateway` for client-to-client device pool flows.

    We track the authorizations we've sent so that, when a policy_authorization is deleted, we can
    push `reject_access` for the corresponding `(initiating_client, resource)` pair. The peer
    recovers by tripping ICMP "destination prohibited" and requesting a fresh flow.

    Data structure:

      %{policy_authorization_id:uuidv4:16 =>
          {client_id:uuidv4:16, resource_id:uuidv4:16, policy_id:uuidv4:16, expires_at:integer:8}}

    Memory characteristics match `Portal.Cache.Gateway` since the structure is identical.
  """

  alias Portal.{Cache, Device}
  alias __MODULE__.Database
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  require OpenTelemetry.Tracer

  @type entry ::
          {client_id :: Cache.Cacheable.uuid_binary(),
           resource_id :: Cache.Cacheable.uuid_binary(),
           policy_id :: Cache.Cacheable.uuid_binary(), expires_at_unix :: non_neg_integer()}
  @type t :: %{(policy_authorization_id :: Cache.Cacheable.uuid_binary()) => entry()}

  @doc """
    Fetches relevant policy_authorizations from the DB and transforms them into the cache format.
  """
  @spec hydrate(Device.t()) :: t()
  def hydrate(client) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.Client.Authorizations.hydrate",
      attributes: %{
        client_id: client.id,
        account_id: client.account_id
      } do
      Database.all_client_policy_authorizations_for_cache!(client)
      |> Map.new(fn {id, client_id, resource_id, policy_id, expires_at} ->
        {dump!(id),
         {dump!(client_id), dump!(resource_id), dump!(policy_id),
          DateTime.to_unix(expires_at, :second)}}
      end)
    end
  end

  @doc """
    Removes expired policy_authorizations from the cache.
  """
  @spec prune(t()) :: t()
  def prune(cache) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

    for {id, {_cid, _rid, _pid, expires_at_unix} = entry} <- cache,
        expires_at_unix >= now_unix,
        into: %{} do
      {id, entry}
    end
  end

  @doc """
    Add a policy_authorization to the cache. Returns the updated cache.
  """
  @spec put(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(
        %{} = cache,
        policy_authorization_id,
        client_id,
        resource_id,
        policy_id,
        %DateTime{} = expires_at
      ) do
    Map.put(
      cache,
      dump_uuid(policy_authorization_id),
      {dump_uuid(client_id), dump_uuid(resource_id), dump_uuid(policy_id),
       DateTime.to_unix(expires_at, :second)}
    )
  end

  @doc """
    Remove a policy_authorization from the cache by id. Returns the `(initiating_client, resource)`
    pair and its cached expiration so the caller can decide whether to push `reject_access`.
  """
  @spec delete(t(), Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer(), t()} | :error
  def delete(%{} = cache, policy_authorization_id) do
    case Map.pop(cache, dump_uuid(policy_authorization_id)) do
      {nil, _cache} ->
        :error

      {{cid_bytes, rid_bytes, _pid_bytes, expires_at_unix}, cache} ->
        {:ok, load!(cid_bytes), load!(rid_bytes), expires_at_unix, cache}
    end
  end

  @doc """
    Check if the cache has any entry for the given resource_id.
  """
  @spec has_resource?(t(), Ecto.UUID.t()) :: boolean()
  def has_resource?(%{} = cache, resource_id) do
    rid_bytes = dump_uuid(resource_id)

    Enum.any?(cache, fn {_id, {_cid, rid, _pid, _exp}} -> rid == rid_bytes end)
  end

  @doc """
    Return a list of all `{client_id, resource_id}` pairs matching the given resource ID.
  """
  @spec all_pairs_for_resource(t(), Ecto.UUID.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def all_pairs_for_resource(%{} = cache, resource_id) do
    rid_bytes = dump_uuid(resource_id)

    cache
    |> Enum.filter(fn {_id, {_cid, rid, _pid, _exp}} -> rid == rid_bytes end)
    |> Enum.map(fn {_id, {cid, _rid, _pid, _exp}} -> {load!(cid), load!(rid_bytes)} end)
    |> Enum.uniq()
  end

  # Accepts either a UUID string or an already-dumped 16-byte binary, so callers
  # can pass rendered (string id) or `Cache.Cacheable` (binary id) resources.
  defp dump_uuid(<<_::128>> = bytes), do: bytes
  defp dump_uuid(uuid) when is_binary(uuid), do: dump!(uuid)

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def all_client_policy_authorizations_for_cache!(%{account_id: _, id: _} = client) do
      now = DateTime.utc_now()

      from(pa in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.account_id == ^client.account_id)
      |> where([policy_authorizations: pa], pa.receiving_device_id == ^client.id)
      |> where([policy_authorizations: pa], pa.expires_at > ^now)
      |> select(
        [policy_authorizations: pa],
        {pa.id, pa.initiating_device_id, pa.resource_id, pa.policy_id, pa.expires_at}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
