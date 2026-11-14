defmodule Portal.Google.Avatars do
  @moduledoc """
  Oban worker that copies the profile photos of a Google directory's users to
  `Portal.Avatars`. The full sync queues it, and it runs at most once every
  six hours per directory.

  The user list carries each photo's version, so only photos with a new
  version are downloaded.
  """
  use Oban.Worker,
    queue: :google_sync,
    max_attempts: 3,
    unique: [
      period: 6 * 60 * 60,
      states: [:available, :scheduled, :executing, :retryable, :completed],
      keys: [:directory_id]
    ]

  alias Portal.Avatars
  alias Portal.DirectorySync
  alias Portal.Google

  @impl Oban.Worker
  def timeout(_job), do: DirectorySync.full_sync_timeout()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "directory_id" => directory_id}}) do
    with true <- Avatars.enabled?(),
         %Google.Directory{} = directory <- Google.Sync.get_directory(account_id, directory_id) do
      access_token = Google.Sync.get_access_token!(directory)

      account_id
      |> Avatars.list_identities(directory_id)
      |> Avatars.reconcile(photo_etags(access_token), &fetch_photos(access_token, &1))

      Avatars.prune(account_id, directory_id)
    end

    :ok
  end

  defp photo_etags(access_token) do
    access_token
    |> Google.APIClient.stream_user_photo_etags()
    |> Enum.reduce(%{}, fn
      {:error, reason}, _acc ->
        raise "Google user photo list failed: #{inspect(reason)}"

      users, acc when is_list(users) ->
        for %{"id" => id} = user <- users, into: acc, do: {id, photo_etag(user)}
    end)
  end

  defp photo_etag(%{"thumbnailPhotoUrl" => url, "thumbnailPhotoEtag" => etag})
       when is_binary(url) and is_binary(etag) and etag != "",
       do: etag

  defp photo_etag(_user), do: nil

  # A photo that fails to download is tried again on the next run.
  defp fetch_photos(access_token, identities) do
    for identity <- identities,
        {:ok, %Req.Response{status: 200, body: %{"photoData" => data}}} <-
          [Google.APIClient.get_user_photo(access_token, identity.idp_id)],
        {:ok, bytes} <- [decode_photo_data(data)],
        into: %{},
        do: {identity.idp_id, bytes}
  end

  # Google's "web-safe" base64 uses - and _ like base64url, but pads with *
  # (or . in some responses) instead of =.
  defp decode_photo_data(data) when is_binary(data) do
    data
    |> String.replace(["*", ".", "="], "")
    |> Base.url_decode64(padding: false)
  end

  defp decode_photo_data(_data), do: :error
end
