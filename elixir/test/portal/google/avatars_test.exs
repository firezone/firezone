defmodule Portal.Google.AvatarsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.AvatarStorageHelpers
  import Portal.GoogleAPIClientHelpers
  import Portal.GoogleDirectoryFixtures
  import Portal.IdentityFixtures

  alias Portal.ExternalIdentity
  alias Portal.Google.APIClient
  alias Portal.Google.Avatars

  setup do
    configure_google_api_client()
    account = account_fixture(features: %{idp_sync: true})
    directory = google_directory_fixture(account: account)
    %{directory: directory, store: stub_avatar_storage()}
  end

  test "stores new photos and records their version", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1")
    stub_google(%{"user-1" => {"etag-1", jpeg()}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-1"
    assert blobs(store) == %{blob_name(identity, "etag-1") => {jpeg(), "image/jpeg"}}
  end

  test "only downloads photos whose version changed", %{directory: directory, store: store} do
    same = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_source: :directory, avatar_etag: "etag-1")
    changed = directory_identity_fixture(directory: directory, idp_id: "user-2", avatar_source: :directory, avatar_etag: "old")
    put_blob(store, blob_name(same), jpeg())
    put_blob(store, blob_name(changed), jpeg())
    stub_google(%{"user-1" => {"etag-1", png()}, "user-2" => {"etag-2", png()}})

    assert :ok = perform_job(Avatars, args(directory))

    assert_received {:google_photo, "user-2"}
    refute_received {:google_photo, "user-1"}
    assert reload(changed).avatar_etag == "etag-2"

    assert blobs(store) == %{
             blob_name(same) => {jpeg(), "image/jpeg"},
             blob_name(changed) => {jpeg(), "image/jpeg"},
             blob_name(changed, "etag-2") => {png(), "image/png"}
           }
  end

  test "deletes the photo of a user who removed it", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_source: :directory, avatar_etag: "etag-1")
    put_blob(store, blob_name(identity), jpeg())
    stub_google(%{"user-1" => :none})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == nil
    assert blobs(store) == %{}
  end

  test "leaves users that are not in the list alone", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_source: :directory, avatar_etag: "etag-1")
    put_blob(store, blob_name(identity), jpeg())
    stub_google(%{})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-1"
    assert Map.has_key?(blobs(store), blob_name(identity))
  end

  test "decodes Google's web-safe base64 padding", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1")
    bytes = jpeg() <> "x"
    stub_google(%{"user-1" => {"etag-1", bytes}})

    assert :ok = perform_job(Avatars, args(directory))

    assert blobs(store) == %{blob_name(identity, "etag-1") => {bytes, "image/jpeg"}}
  end

  test "does nothing without a container", %{directory: directory} do
    Portal.Config.put_env_override(:avatars_container_url, nil)
    directory_identity_fixture(directory: directory, idp_id: "user-1")

    assert :ok = perform_job(Avatars, args(directory))
  end

  defp args(directory), do: %{account_id: directory.account_id, directory_id: directory.id}

  defp reload(identity), do: Repo.get_by!(ExternalIdentity, account_id: identity.account_id, id: identity.id)

  # `photos` maps a user id to `{etag, bytes}` or `:none`.
  defp stub_google(photos) do
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      case conn.request_path do
        "/token" ->
          Req.Test.json(conn, %{"access_token" => "token", "expires_in" => 3600})

        "/admin/directory/v1/users" ->
          users =
            Enum.map(photos, fn
              {id, :none} -> %{"id" => id, "thumbnailPhotoEtag" => "\"no-photo\""}
              {id, {etag, _bytes}} -> %{"id" => id, "thumbnailPhotoUrl" => "https://photo/#{id}", "thumbnailPhotoEtag" => etag}
            end)

          Req.Test.json(conn, %{"users" => users})

        "/admin/directory/v1/users/" <> rest ->
          [id, "photos", "thumbnail"] = String.split(rest, "/")
          send(test_pid, {:google_photo, id})
          {_etag, bytes} = photos[id]
          Req.Test.json(conn, %{"photoData" => web_safe_base64(bytes), "mimeType" => "image/jpeg"})
      end
    end)
  end

  defp web_safe_base64(bytes), do: bytes |> Base.url_encode64() |> String.replace("=", "*")
end
