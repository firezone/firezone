defmodule Portal.Avatars do
  @moduledoc """
  Profile photos of external identities, copied into our own blob container.

  A photo comes from one of two sources, kept in `avatar_source`:

    * `:directory` - Entra or Google directory sync. It wins over the other.
    * `:picture` - the `picture` claim of the identity's last sign-in.

  `avatar_etag` holds the photo's version, so a photo is only stored again
  when its version changes. Each version is its own blob,
  `<account_id>/<identity_id>/<version>`, so a write never replaces the photo
  that the portal links to. `prune/0` deletes the blobs that nothing links to.
  """
  alias __MODULE__.Database
  alias __MODULE__.Storage
  alias Portal.ExternalIdentity
  require Logger

  # Photos are 96x96 and a few KB. This only stops a bad response.
  @max_bytes 512 * 1024

  # A blob this new may belong to a photo whose version is not saved yet.
  @prune_grace_seconds 60 * 60

  def enabled?, do: not is_nil(Portal.Config.fetch_env!(:portal, :avatars_container_url))

  def max_bytes, do: @max_bytes

  def list_identities(account_id, directory_id), do: Database.list_identities(account_id, directory_id)

  @doc """
  Brings the directory photos of `identities` up to date.

  `etags` maps an identity's `idp_id` to the directory's current photo
  version, or to `nil` when the user has no photo. Identities missing from
  `etags` are left as they are. `fetch` gets the identities whose photo
  changed and returns the photo bytes by `idp_id`. A photo it does not return
  is tried again on the next run.

  A directory photo replaces a sign-in photo. When the directory photo goes
  away, the sign-in photo is fetched again.
  """
  def reconcile(identities, etags, fetch) when is_function(fetch, 1) do
    {removed, updated} =
      identities
      |> Enum.filter(&(Map.has_key?(etags, &1.idp_id) and directory_photo_changed?(&1, etags[&1.idp_id])))
      |> Enum.split_with(&is_nil(etags[&1.idp_id]))

    for identity <- removed do
      :ok = clear(identity)
      :ok = __MODULE__.Picture.enqueue(%{identity | avatar_source: nil, avatar_etag: nil})
    end

    photos = if updated == [], do: %{}, else: fetch.(updated)

    for identity <- updated, {:ok, body} <- [Map.fetch(photos, identity.idp_id)] do
      store(identity, :directory, etags[identity.idp_id], body)
    end

    :ok
  end

  @doc """
  Stores a photo unless it is not a JPEG or PNG under the size limit. A
  sign-in photo is not saved over a directory photo.
  """
  def store(%ExternalIdentity{} = identity, source, etag, body) when source in [:directory, :picture] do
    case image_type(body) do
      type when is_binary(type) and byte_size(body) <= @max_bytes ->
        :ok = Storage.put!(blob_name(identity, etag), body, type)
        Database.set_avatar(identity, source, etag)

      _other ->
        Logger.info("Skipping profile photo that is not a JPEG or PNG under #{@max_bytes} bytes",
          account_id: identity.account_id,
          external_identity_id: identity.id,
          size: byte_size(body)
        )
    end

    :ok
  end

  @doc """
  Deletes an identity's photo, unless the database already holds another one.
  The version goes first, so the portal never links a photo that is gone.
  """
  def clear(%ExternalIdentity{avatar_etag: etag} = identity) when is_binary(etag) do
    if Database.clear_avatar(identity) == 1 do
      Storage.delete!(blob_name(identity, etag))
    end

    :ok
  end

  def clear(%ExternalIdentity{}), do: :ok

  @doc """
  Deletes every blob that no identity links to: old versions, photos of
  deleted identities and photos of deleted accounts.
  """
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@prune_grace_seconds)

    ""
    |> Storage.stream!()
    |> Enum.each(fn blobs ->
      blobs = Enum.filter(blobs, fn {_name, last_modified} -> DateTime.before?(last_modified, cutoff) end)
      kept = linked_blob_names(blobs)

      for {name, _last_modified} <- blobs, not MapSet.member?(kept, name) do
        Storage.delete!(name)
      end
    end)
  end

  @doc """
  Deletes every photo of an account.
  """
  def delete_account(account_id) do
    "#{account_id}/"
    |> Storage.stream!()
    |> Stream.concat()
    |> Enum.each(fn {name, _last_modified} -> Storage.delete!(name) end)
  end

  @doc """
  Sets the actor's photo fields to its best photo: a directory photo first,
  then the newest sign-in photo.
  """
  def put_actor_avatar(%Portal.Actor{} = actor) do
    case Database.get_actor_avatar(actor.account_id, actor.id) do
      {identity_id, etag} -> %{actor | avatar_identity_id: identity_id, avatar_etag: etag}
      nil -> actor
    end
  end

  @doc """
  Returns the stored photo of an identity and its content type.
  """
  def fetch(%ExternalIdentity{avatar_etag: etag} = identity) when is_binary(etag) do
    with {:ok, body} <- Storage.get(blob_name(identity, etag)),
         type when is_binary(type) <- image_type(body) do
      {:ok, body, type}
    else
      nil -> {:error, :invalid_image}
      {:error, _reason} = error -> error
    end
  end

  def fetch(%ExternalIdentity{}), do: {:error, :not_found}

  @doc """
  A short version of a photo for its URL and blob name, so browsers can cache
  each one for good and still load a new one when it changes.
  """
  def version(etag) when is_binary(etag) do
    :crypto.hash(:sha256, etag) |> binary_part(0, 9) |> Base.url_encode64(padding: false)
  end

  defp directory_photo_changed?(%{avatar_source: :directory, avatar_etag: stored}, etag), do: etag != stored
  defp directory_photo_changed?(_identity, etag), do: not is_nil(etag)

  defp blob_name(identity, etag), do: "#{identity.account_id}/#{identity.id}/#{version(etag)}"

  defp linked_blob_names(blobs) do
    keys =
      for {name, _last_modified} <- blobs,
          [account_id, id, _version] <- [String.split(name, "/")],
          {:ok, account_id} <- [Ecto.UUID.cast(account_id)],
          {:ok, id} <- [Ecto.UUID.cast(id)],
          do: {account_id, id}

    keys
    |> Database.list_avatar_etags()
    |> MapSet.new(fn {account_id, id, etag} -> "#{account_id}/#{id}/#{version(etag)}" end)
  end

  # The bytes decide the content type, never the provider, so the portal only
  # ever serves images.
  defp image_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp image_type(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: "image/png"
  defp image_type(_body), do: nil

  defmodule Database do
    import Ecto.Query
    alias Portal.ExternalIdentity
    alias Portal.Safe

    @fields [:account_id, :directory_id, :id, :idp_id, :picture, :avatar_source, :avatar_etag]

    def list_identities(account_id, directory_id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and i.directory_id == ^directory_id,
        select: struct(i, ^@fields)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def get_actor_avatar(account_id, actor_id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and i.actor_id == ^actor_id and not is_nil(i.avatar_etag),
        order_by: [desc: i.avatar_source == :directory, desc: i.updated_at, desc: i.id],
        limit: 1,
        select: {i.id, i.avatar_etag}
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def list_avatar_etags([]), do: []

    def list_avatar_etags(keys) do
      {account_ids, ids} = Enum.unzip(keys)

      from(i in ExternalIdentity,
        where: i.account_id in ^Enum.uniq(account_ids) and i.id in ^ids and not is_nil(i.avatar_etag),
        select: {i.account_id, i.id, i.avatar_etag}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def set_avatar(identity, :directory, etag) do
      identity
      |> identity_query()
      |> update_avatar(:directory, etag)
    end

    def set_avatar(identity, :picture, etag) do
      identity
      |> identity_query()
      |> where([i], is_nil(i.avatar_source) or i.avatar_source == :picture)
      |> update_avatar(:picture, etag)
    end

    def clear_avatar(identity) do
      {count, _rows} =
        identity
        |> identity_query()
        |> where([i], i.avatar_source == ^identity.avatar_source and i.avatar_etag == ^identity.avatar_etag)
        |> Safe.unscoped()
        |> Safe.update_all(set: [avatar_source: nil, avatar_etag: nil])

      count
    end

    defp update_avatar(query, source, etag) do
      query
      |> Safe.unscoped()
      |> Safe.update_all(set: [avatar_source: source, avatar_etag: etag])

      :ok
    end

    defp identity_query(identity) do
      from(i in ExternalIdentity, where: i.account_id == ^identity.account_id and i.id == ^identity.id)
    end
  end
end
