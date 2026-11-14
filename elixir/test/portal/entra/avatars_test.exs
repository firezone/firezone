defmodule Portal.Entra.AvatarsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.AvatarStorageHelpers
  import Portal.EntraDirectoryFixtures
  import Portal.IdentityFixtures

  alias Portal.Entra.Avatars
  alias Portal.ExternalIdentity
  alias Portal.Microsoft.Graph.APIClient

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account)
    %{account: account, directory: directory, store: stub_avatar_storage()}
  end

  test "stores new photos and records their version", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1")
    stub_graph(%{"user-1" => {"etag-1", jpeg()}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-1"
    assert blobs(store) == %{blob_name(identity) => {jpeg(), "image/jpeg"}}
  end

  test "does not download a photo whose version did not change", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_etag: "etag-1")
    put_blob(store, blob_name(identity), jpeg())
    stub_graph(%{"user-1" => {"etag-1", png()}})

    assert :ok = perform_job(Avatars, args(directory))

    assert_received {:graph_batch, ["/users/user-1/photo"]}
    refute_received {:graph_batch, _paths}
    assert blobs(store) == %{blob_name(identity) => {jpeg(), "image/jpeg"}}
  end

  test "replaces a photo whose version changed", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_etag: "etag-1")
    put_blob(store, blob_name(identity), jpeg())
    stub_graph(%{"user-1" => {"etag-2", png()}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-2"
    assert blobs(store) == %{blob_name(identity) => {png(), "image/png"}}
  end

  test "deletes the photo of a user who removed it", %{directory: directory, store: store} do
    with_404 = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_etag: "etag-1")
    placeholder = directory_identity_fixture(directory: directory, idp_id: "user-2", avatar_etag: "etag-2")
    put_blob(store, blob_name(with_404), jpeg())
    put_blob(store, blob_name(placeholder), jpeg())
    stub_graph(%{"user-1" => :none, "user-2" => {"", nil}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(with_404).avatar_etag == nil
    assert reload(placeholder).avatar_etag == nil
    assert blobs(store) == %{}
  end

  test "uses the largest photo when there is no 96x96 one", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1")
    stub_graph(%{"user-1" => {"etag-1", {:largest_only, jpeg()}}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-1"
    assert blobs(store) == %{blob_name(identity) => {jpeg(), "image/jpeg"}}
  end

  test "keeps the old version when a photo is not an image", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1")
    stub_graph(%{"user-1" => {"etag-1", "<html>not a photo</html>"}})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == nil
    assert blobs(store) == %{}
  end

  test "leaves a user alone when Graph fails for it", %{directory: directory, store: store} do
    identity = directory_identity_fixture(directory: directory, idp_id: "user-1", avatar_etag: "etag-1")
    put_blob(store, blob_name(identity), jpeg())
    stub_graph(%{"user-1" => :throttled})

    assert :ok = perform_job(Avatars, args(directory))

    assert reload(identity).avatar_etag == "etag-1"
    assert Map.has_key?(blobs(store), blob_name(identity))
  end

  test "deletes photos of identities that are gone", %{account: account, directory: directory, store: store} do
    other_directory = entra_directory_fixture(account: account)
    orphan = "#{directory.account_id}/#{directory.id}/#{Ecto.UUID.generate()}"
    elsewhere = "#{directory.account_id}/#{other_directory.id}/#{Ecto.UUID.generate()}"
    put_blob(store, orphan, jpeg())
    put_blob(store, elsewhere, jpeg())
    stub_graph(%{})

    assert :ok = perform_job(Avatars, args(directory))

    assert Map.keys(blobs(store)) == [elsewhere]
  end

  test "does nothing without a container", %{directory: directory} do
    Portal.Config.put_env_override(:avatars_container_url, nil)
    directory_identity_fixture(directory: directory, idp_id: "user-1")

    assert :ok = perform_job(Avatars, args(directory))
  end

  test "runs at most once in six hours per directory", %{directory: directory} do
    assert {:ok, %{conflict?: false}} = directory |> args() |> Avatars.new() |> Oban.insert()
    assert {:ok, %{conflict?: true}} = directory |> args() |> Avatars.new() |> Oban.insert()
  end

  defp args(directory), do: %{account_id: directory.account_id, directory_id: directory.id}

  defp reload(identity), do: Repo.get_by!(ExternalIdentity, account_id: identity.account_id, id: identity.id)

  # `photos` maps a user id to `{etag, bytes}`, `{etag, {:largest_only, bytes}}`,
  # `:none` (404), or `:throttled` (429).
  defp stub_graph(photos) do
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        Req.Test.json(conn, %{"access_token" => "token"})
      else
        "/v1.0/$batch" = conn.request_path
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        requests = JSON.decode!(body)["requests"]
        send(test_pid, {:graph_batch, Enum.map(requests, & &1["url"])})

        responses = Enum.map(requests, &Map.put(graph_response(photos, &1["url"]), "id", &1["id"]))
        Req.Test.json(conn, %{"responses" => responses})
      end
    end)
  end

  defp graph_response(photos, url) do
    case Regex.run(~r{^/users/([^/]+)/(photo|photos/96x96)(/\$value)?$}, url) do
      [_url, user_id, kind] -> metadata(photos[user_id], kind)
      [_url, user_id, kind, _value] -> bytes(photos[user_id], kind)
    end
  end

  defp metadata(:throttled, _kind), do: %{"status" => 429, "body" => %{}}
  defp metadata(:none, _kind), do: %{"status" => 404, "body" => %{}}

  defp metadata({etag, _bytes}, "photo"),
    do: %{"status" => 200, "body" => %{"@odata.mediaEtag" => etag, "id" => "96X96"}}

  defp bytes({_etag, {:largest_only, _bytes}}, "photos/96x96"), do: %{"status" => 404, "body" => %{}}
  defp bytes({_etag, {:largest_only, bytes}}, "photo"), do: encoded(bytes)
  defp bytes({_etag, bytes}, _kind), do: encoded(bytes)

  defp encoded(bytes), do: %{"status" => 200, "body" => Base.encode64(bytes)}
end
