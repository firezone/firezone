defmodule Portal.Cache.Inbound do
  @moduledoc """
    The inbound half of a device channel's state: a materialized view of the
    policy_authorizations where the channel's device is the `receiving_device_id`,
    a gateway serving a resource or a client reached through a device pool. The
    cache is seeded on join and updated via WAL messages streamed from the
    Portal.Changes.Consumer module.

    It mirrors the data plane, which keeps a single authorization per
    `(initiating_device, resource)` pair (last-one-wins): a fresh authorization for a
    pair supersedes the previous one. We track the currently-authorized
    `policy_authorization_id` per pair so that, when a policy_authorization is
    deleted, we only push `reject_access` if the deleted row is the one currently
    granting access. A delete for a superseded authorization is ignored. The
    initiator recovers from a reject by tripping ICMP "destination prohibited" and
    requesting a fresh authorization.

    We use basic data structures and binary representations instead of full Ecto
    schema structs to minimize memory usage.

    Data structure:

      %{{initiating_device_id:uuidv4:16, resource_id:uuidv4:16} =>
          {policy_authorization_id:uuidv4:16, expires_at:integer:8}}
  """

  alias Portal.{Cache, Device}
  alias __MODULE__.Database
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  require OpenTelemetry.Tracer

  @type initiator_resource_key ::
          {initiating_device_id :: Cache.Cacheable.uuid_binary(),
           resource_id :: Cache.Cacheable.uuid_binary()}
  @type entry ::
          {policy_authorization_id :: Cache.Cacheable.uuid_binary(),
           expires_at_unix :: non_neg_integer()}
  @type t :: %{initiator_resource_key() => entry()}

  @doc """
    Fetches relevant policy_authorizations from the DB and transforms them into the cache format.
    When more than one non-expired authorization exists for a pair, the longest-expiring one is
    kept to minimize unnecessary access churn.
  """
  @spec hydrate(Device.t()) :: t()
  def hydrate(device) do
    OpenTelemetry.Tracer.with_span "Portal.Cache.Inbound.hydrate",
      attributes: %{
        device_id: device.id,
        account_id: device.account_id
      } do
      Database.all_inbound_policy_authorizations!(device)
      |> Enum.reduce(%{}, &put_hydrated/2)
    end
  end

  defp put_hydrated({id, client_id, resource_id, expires_at}, acc) do
    key = {dump!(client_id), dump!(resource_id)}
    expires_at_unix = DateTime.to_unix(expires_at, :second)

    case acc do
      %{^key => {_pa_id, prev_expires_at}} when prev_expires_at >= expires_at_unix ->
        acc

      _ ->
        Map.put(acc, key, {dump!(id), expires_at_unix})
    end
  end

  @doc """
    Removes expired authorizations from the cache.
  """
  @spec prune(t()) :: t()
  def prune(cache) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

    for {key, {_pa_id, expires_at_unix} = entry} <- cache,
        expires_at_unix >= now_unix,
        into: %{} do
      {key, entry}
    end
  end

  @doc """
    Record the authorization currently granting access to an `(initiating_device, resource)`
    pair. Last-one-wins: a newer authorization for the same pair supersedes the previous one.
  """
  @spec put(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(
        %{} = cache,
        policy_authorization_id,
        initiating_device_id,
        resource_id,
        %DateTime{} = expires_at
      ) do
    Map.put(
      cache,
      {dump_uuid(initiating_device_id), dump_uuid(resource_id)},
      {dump_uuid(policy_authorization_id), DateTime.to_unix(expires_at, :second)}
    )
  end

  @doc """
    Remove a deleted policy_authorization from the cache. Only acts when the deleted row is the one
    currently cached for its `(initiating_device, resource)` pair; a delete for a superseded
    authorization is a no-op. Returns the cached expiration so the caller can decide whether to push
    `reject_access`.
  """
  @spec delete(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer(), t()} | :error
  def delete(%{} = cache, policy_authorization_id, initiating_device_id, resource_id) do
    key = {dump_uuid(initiating_device_id), dump_uuid(resource_id)}
    pa_id_bytes = dump_uuid(policy_authorization_id)

    case Map.get(cache, key) do
      {^pa_id_bytes, expires_at_unix} ->
        {:ok, expires_at_unix, Map.delete(cache, key)}

      _ ->
        :error
    end
  end

  @doc """
    Check if the cache has an entry for the given resource_id.
  """
  @spec has_resource?(t(), Ecto.UUID.t()) :: boolean()
  def has_resource?(%{} = cache, resource_id) do
    rid_bytes = dump_uuid(resource_id)

    Enum.any?(cache, fn {{_cid, rid}, _entry} -> rid == rid_bytes end)
  end

  @doc """
    Return a list of all `{initiating_device_id, resource_id}` pairs matching the given resource ID.
  """
  @spec all_pairs_for_resource(t(), Ecto.UUID.t()) :: [{Ecto.UUID.t(), Ecto.UUID.t()}]
  def all_pairs_for_resource(%{} = cache, resource_id) do
    rid_bytes = dump_uuid(resource_id)

    for {{cid, rid}, _entry} <- cache, rid == rid_bytes do
      {load!(cid), load!(rid)}
    end
  end

  # Accepts either a UUID string or an already-dumped 16-byte binary, so callers
  # can pass rendered (string id) or `Cache.Cacheable` (binary id) resources.
  defp dump_uuid(<<_::128>> = bytes), do: bytes
  defp dump_uuid(uuid) when is_binary(uuid), do: dump!(uuid)

  defmodule Database do
    alias Portal.Safe
    import Ecto.Query

    def all_inbound_policy_authorizations!(%{account_id: _, id: _} = device) do
      now = DateTime.utc_now()

      from(f in Portal.PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^device.account_id)
      |> where([policy_authorizations: f], f.receiving_device_id == ^device.id)
      |> where([policy_authorizations: f], f.expires_at > ^now)
      # Longest-expiring first so the per-pair last-one-wins reduction is deterministic.
      |> order_by([policy_authorizations: f], desc: f.expires_at)
      |> select(
        [policy_authorizations: f],
        {f.id, f.initiating_device_id, f.resource_id, f.expires_at}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
