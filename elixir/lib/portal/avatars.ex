defmodule Portal.Avatars do
  @moduledoc """
  Profile photos that directory sync copies from Entra and Google.

  Each photo is the blob `<account_id>/<directory_id>/<identity_id>`, and the
  identity's `avatar_etag` holds the provider's version of it. A photo is only
  downloaded and stored again when the provider reports a different version.
  """
  alias __MODULE__.Database
  alias __MODULE__.Storage
  alias Portal.ExternalIdentity
  require Logger

  # Providers return 96x96 photos of a few KB. This only stops a bad response.
  @max_bytes 512 * 1024

  def enabled?, do: not is_nil(Portal.Config.fetch_env!(:portal, :avatars_container_url))

  def list_identities(account_id, directory_id), do: Database.list_identities(account_id, directory_id)

  @doc """
  Brings the stored photos of `identities` up to date.

  `etags` maps an identity's `idp_id` to the provider's current photo version,
  or to `nil` when the user has no photo. Identities missing from `etags` are
  left as they are. `fetch` gets the identities whose photo changed and returns
  the photo bytes by `idp_id`. A photo it does not return is tried again on the
  next run.
  """
  def reconcile(identities, etags, fetch) when is_function(fetch, 1) do
    changed =
      for identity <- identities,
          Map.has_key?(etags, identity.idp_id),
          etags[identity.idp_id] != identity.avatar_etag,
          do: identity

    {removed, updated} = Enum.split_with(changed, &is_nil(etags[&1.idp_id]))

    Enum.each(removed, &clear/1)

    photos = if updated == [], do: %{}, else: fetch.(updated)

    for identity <- updated, {:ok, body} <- [Map.fetch(photos, identity.idp_id)] do
      store(identity, etags[identity.idp_id], body)
    end

    :ok
  end

  @doc """
  Deletes the photos of a directory whose identity no longer has one, such as
  identities that sync deleted.
  """
  def prune(account_id, directory_id) do
    kept = account_id |> Database.list_identity_ids_with_avatar(directory_id) |> MapSet.new()
    prefix = "#{account_id}/#{directory_id}/"

    for name <- Storage.list!(prefix),
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

  defp store(identity, etag, body) do
    case image_type(body) do
      type when is_binary(type) and byte_size(body) <= @max_bytes ->
        :ok = Storage.put!(blob_name(identity), body, type)
        Database.set_etag(identity, etag)

      _other ->
        Logger.info("Skipping profile photo that is not a JPEG or PNG under #{@max_bytes} bytes",
          account_id: identity.account_id,
          external_identity_id: identity.id,
          size: byte_size(body)
        )
    end
  end

  # The etag goes first, so the portal never links a photo that is gone.
  defp clear(identity) do
    Database.set_etag(identity, nil)
    Storage.delete!(blob_name(identity))
  end

  defp blob_name(identity), do: "#{identity.account_id}/#{identity.directory_id}/#{identity.id}"

  # The bytes decide the content type, never the provider, so the portal only
  # ever serves images.
  defp image_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp image_type(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: "image/png"
  defp image_type(_body), do: nil

  defmodule Database do
    import Ecto.Query
    alias Portal.ExternalIdentity
    alias Portal.Safe

    def list_identities(account_id, directory_id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and i.directory_id == ^directory_id,
        select: struct(i, [:account_id, :directory_id, :id, :idp_id, :avatar_etag])
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def list_identity_ids_with_avatar(account_id, directory_id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and i.directory_id == ^directory_id,
        where: not is_nil(i.avatar_etag),
        select: i.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def set_etag(identity, etag) do
      from(i in ExternalIdentity, where: i.account_id == ^identity.account_id and i.id == ^identity.id)
      |> Safe.unscoped()
      |> Safe.update_all(set: [avatar_etag: etag])

      :ok
    end
  end
end
