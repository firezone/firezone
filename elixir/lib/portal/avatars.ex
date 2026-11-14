defmodule Portal.Avatars do
  @moduledoc """
  Profile photos of external identities, copied into our own blob container.

  A photo comes from one of two sources, kept in `avatar_source`:

    * `:directory` - Entra or Google directory sync. It wins over the other.
    * `:picture` - the `picture` claim of the identity's last sign-in.

  Each photo is the blob `<account_id>/<identity_id>`, and `avatar_etag` holds
  its version, so a photo is only stored again when its version changes.
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

  A directory photo replaces a sign-in photo. A user without a directory photo
  keeps their sign-in photo.
  """
  def reconcile(identities, etags, fetch) when is_function(fetch, 1) do
    {removed, updated} =
      identities
      |> Enum.filter(&(Map.has_key?(etags, &1.idp_id) and directory_photo_changed?(&1, etags[&1.idp_id])))
      |> Enum.split_with(&is_nil(etags[&1.idp_id]))

    Enum.each(removed, &clear/1)

    photos = if updated == [], do: %{}, else: fetch.(updated)

    for identity <- updated, {:ok, body} <- [Map.fetch(photos, identity.idp_id)] do
      store(identity, :directory, etags[identity.idp_id], body)
    end

    :ok
  end

  @doc """
  Stores a photo unless it is not a JPEG or PNG under the size limit.
  """
  def store(%ExternalIdentity{} = identity, source, version, body) do
    case image_type(body) do
      type when is_binary(type) and byte_size(body) <= @max_bytes ->
        :ok = Storage.put!(blob_name(identity), body, type)
        Database.set_avatar(identity, source, version)

      _other ->
        Logger.info("Skipping profile photo that is not a JPEG or PNG under #{@max_bytes} bytes",
          account_id: identity.account_id,
          external_identity_id: identity.id,
          size: byte_size(body)
        )
    end
  end

  @doc """
  Deletes an identity's photo. The version goes first, so the portal never
  links a photo that is gone.
  """
  def clear(%ExternalIdentity{} = identity) do
    Database.set_avatar(identity, nil, nil)
    Storage.delete!(blob_name(identity))
  end

  @doc """
  Deletes the photos of an account whose identity no longer has one, such as
  identities that were deleted.
  """
  def prune(account_id) do
    kept = account_id |> Database.list_identity_ids_with_avatar() |> MapSet.new()
    prefix = "#{account_id}/"
    cutoff = DateTime.add(DateTime.utc_now(), -@prune_grace_seconds)

    for {name, last_modified} <- Storage.list!(prefix),
        DateTime.before?(last_modified, cutoff),
        not MapSet.member?(kept, String.replace_prefix(name, prefix, "")) do
      Storage.delete!(name)
    end

    :ok
  end

  @doc """
  Returns the stored photo of an identity and its content type.
  """
  def fetch(%ExternalIdentity{avatar_etag: etag} = identity) when is_binary(etag) do
    with {:ok, body} <- Storage.get(blob_name(identity)),
         type when is_binary(type) <- image_type(body) do
      {:ok, body, type}
    else
      nil -> {:error, :invalid_image}
      {:error, _reason} = error -> error
    end
  end

  def fetch(%ExternalIdentity{}), do: {:error, :not_found}

  @doc """
  A short version of a photo for its URL, so browsers can cache each one for
  good and still load a new one when it changes.
  """
  def version(etag) when is_binary(etag) do
    :crypto.hash(:sha256, etag) |> binary_part(0, 9) |> Base.url_encode64(padding: false)
  end

  defp directory_photo_changed?(%{avatar_source: :directory, avatar_etag: stored}, etag), do: etag != stored
  defp directory_photo_changed?(_identity, etag), do: not is_nil(etag)

  defp blob_name(identity), do: "#{identity.account_id}/#{identity.id}"

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

    def list_identity_ids_with_avatar(account_id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and not is_nil(i.avatar_etag),
        select: i.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def set_avatar(identity, source, etag) do
      from(i in ExternalIdentity, where: i.account_id == ^identity.account_id and i.id == ^identity.id)
      |> Safe.unscoped()
      |> Safe.update_all(set: [avatar_source: source, avatar_etag: etag])

      :ok
    end
  end
end
