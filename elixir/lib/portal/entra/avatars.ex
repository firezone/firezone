defmodule Portal.Entra.Avatars do
  @moduledoc """
  Oban worker that copies the profile photos of an Entra directory's users to
  `Portal.Avatars`. The full sync queues it, and it runs at most once every
  six hours per directory.

  Graph has no photo version in its user list, so each run reads the photo
  metadata of every user in batches of 20. Only photos with a new version are
  downloaded.
  """
  use Oban.Worker,
    queue: :entra_sync,
    max_attempts: 3,
    unique: [
      period: 6 * 60 * 60,
      states: [:available, :scheduled, :executing, :retryable, :completed],
      keys: [:directory_id]
    ]

  alias Portal.Avatars
  alias Portal.DirectorySync
  alias Portal.Entra
  alias Portal.Microsoft.Graph.APIClient

  @batch_size 20

  @impl Oban.Worker
  def timeout(_job), do: DirectorySync.full_sync_timeout()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "directory_id" => directory_id}}) do
    with true <- Avatars.enabled?(),
         %Entra.Directory{} = directory <- Entra.Sync.get_directory(account_id, directory_id) do
      access_token = Entra.Sync.get_access_token!(directory)

      account_id
      |> Avatars.list_identities(directory_id)
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(fn identities ->
        etags = photo_etags(access_token, identities)
        Avatars.reconcile(identities, etags, &fetch_photos(access_token, &1))
      end)
    end

    :ok
  end

  # A user without a photo has a 404 or, as the Graph docs show, a 1x1
  # placeholder with an empty etag. Other errors leave the user out, so its
  # photo stays as it is until the next run.
  defp photo_etags(access_token, identities) do
    responses = batch_get!(access_token, Enum.map(identities, &"/users/#{&1.idp_id}/photo"))

    for identity <- identities,
        {:ok, etag} <- [photo_etag(responses["/users/#{identity.idp_id}/photo"])],
        into: %{},
        do: {identity.idp_id, etag}
  end

  defp photo_etag(%{"status" => 200, "body" => %{"@odata.mediaEtag" => etag}})
       when is_binary(etag) and etag != "",
       do: {:ok, etag}

  defp photo_etag(%{"status" => 200}), do: {:ok, nil}
  defp photo_etag(%{"status" => 404}), do: {:ok, nil}
  defp photo_etag(_response), do: :error

  # Graph only has the sizes up to the one the user uploaded, so a photo
  # smaller than 96x96 comes from the largest size instead.
  defp fetch_photos(access_token, identities) do
    sized = fetch_photo_bytes(access_token, identities, &"/users/#{&1}/photos/96x96/$value")
    missing = Enum.reject(identities, &Map.has_key?(sized, &1.idp_id))

    if missing == [] do
      sized
    else
      Map.merge(sized, fetch_photo_bytes(access_token, missing, &"/users/#{&1}/photo/$value"))
    end
  end

  defp fetch_photo_bytes(access_token, identities, path) do
    responses = batch_get!(access_token, Enum.map(identities, &path.(&1.idp_id)))

    for identity <- identities,
        %{"status" => 200, "body" => body} when is_binary(body) <- [responses[path.(identity.idp_id)]],
        {:ok, bytes} <- [Base.decode64(body)],
        into: %{},
        do: {identity.idp_id, bytes}
  end

  defp batch_get!(access_token, paths) do
    case APIClient.batch_get(access_token, paths) do
      {:ok, responses} -> responses
      {:error, reason} -> raise "Graph photo batch failed: #{inspect(reason)}"
    end
  end
end
