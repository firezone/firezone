defmodule Portal.Cache.Authorizations do
  @moduledoc """
    The authorizations a channel process has been told about, one per `(peer, resource)` pair.

    Gateways keep one of these for the clients that may reach them. Clients keep one for the
    clients that may reach them and one for the clients they reach. Like the data plane, a newer
    authorization for a pair supersedes the previous one, and the `policy_authorization_id` that
    currently grants access is tracked so that a delete only pushes `reject_access` when it
    targets that one.

    Ids are stored as 16-byte binaries to keep the cache small.

      %{{peer_id:uuidv4:16, resource_id:uuidv4:16} =>
          {policy_authorization_id:uuidv4:16, expires_at:integer:8}}
  """

  alias Portal.Cache
  import Ecto.UUID, only: [dump!: 1, load!: 1]

  @type client_resource_key ::
          {client_id :: Cache.Cacheable.uuid_binary(),
           resource_id :: Cache.Cacheable.uuid_binary()}
  @type entry ::
          {policy_authorization_id :: Cache.Cacheable.uuid_binary(),
           expires_at_unix :: non_neg_integer()}
  @type t :: %{client_resource_key() => entry()}

  @doc """
    Adds a hydrated authorization, keeping the longest-expiring one when a pair has several.
  """
  @spec put_longest(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put_longest(cache, id, peer_id, resource_id, expires_at) do
    key = {dump!(peer_id), dump!(resource_id)}
    expires_at_unix = DateTime.to_unix(expires_at, :second)

    case cache do
      %{^key => {_pa_id, prev_expires_at}} when prev_expires_at >= expires_at_unix ->
        cache

      _ ->
        Map.put(cache, key, {dump!(id), expires_at_unix})
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
    Record the authorization currently granting access to a `(client, resource)` pair. Last-one-wins:
    a newer authorization for the same pair supersedes the previous one.
  """
  @spec put(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: t()
  def put(
        %{} = cache,
        policy_authorization_id,
        client_id,
        resource_id,
        %DateTime{} = expires_at
      ) do
    Map.put(
      cache,
      {dump_uuid(client_id), dump_uuid(resource_id)},
      {dump_uuid(policy_authorization_id), DateTime.to_unix(expires_at, :second)}
    )
  end

  @doc """
    Remove a deleted policy_authorization from the cache. Only acts when the deleted row is the one
    currently cached for its `(client, resource)` pair; a delete for a superseded authorization is a
    no-op. Returns the cached expiration so the caller can decide whether to push `reject_access`.
  """
  @spec delete(t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer(), t()} | :error
  def delete(%{} = cache, policy_authorization_id, client_id, resource_id) do
    key = {dump_uuid(client_id), dump_uuid(resource_id)}
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
    Check if the cache has an authorization for the given client_id.
  """
  @spec has_client?(t(), String.t()) :: boolean()
  def has_client?(%{} = cache, client_id) when is_binary(client_id) do
    case Ecto.UUID.dump(client_id) do
      {:ok, cid_bytes} -> Enum.any?(cache, fn {{cid, _rid}, _entry} -> cid == cid_bytes end)
      :error -> false
    end
  end

  def has_client?(%{}, _client_id), do: false

  @doc """
    Return the ids of the resources the given client_id is authorized for.
  """
  @spec resource_ids_for_client(t(), String.t()) :: [Ecto.UUID.t()]
  def resource_ids_for_client(%{} = cache, client_id) when is_binary(client_id) do
    case Ecto.UUID.dump(client_id) do
      {:ok, cid_bytes} -> for {{^cid_bytes, rid}, _entry} <- cache, do: load!(rid)
      :error -> []
    end
  end

  @doc """
    Return a list of all `{client_id, resource_id}` pairs matching the given resource ID.
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
end
