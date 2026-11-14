defmodule Portal.Avatars.PictureTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.AvatarStorageHelpers
  import Portal.IdentityFixtures

  alias Portal.Avatars.Picture
  alias Portal.ExternalIdentity

  @url "https://idp.example.com/photo.jpg"

  setup do
    %{account: account_fixture(), store: stub_avatar_storage()}
  end

  test "stores the photo at the picture URL", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: @url)
    stub_picture(200, jpeg())

    assert :ok = perform_job(Picture, args(identity))

    assert %{avatar_source: :picture, avatar_etag: etag} = reload(identity)
    assert etag == sha256(jpeg())
    assert blobs(store) == %{blob_name(identity) => {jpeg(), "image/jpeg"}}
  end

  test "does not store the same photo again", %{account: account, store: store} do
    identity =
      identity_fixture(account: account, picture: @url, avatar_source: :picture, avatar_etag: sha256(jpeg()))

    put_blob(store, blob_name(identity), jpeg(), modified_at: ~U[2020-01-01 00:00:00Z])
    stub_picture(200, jpeg())

    assert :ok = perform_job(Picture, args(identity))

    assert [{_name, {_body, _type, ~U[2020-01-01 00:00:00Z]}}] = Agent.get(store, &Map.to_list/1)
  end

  test "leaves an identity with a directory photo alone", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: @url, avatar_source: :directory, avatar_etag: "graph")
    put_blob(store, blob_name(identity), png())
    stub_picture(200, jpeg())

    assert :ok = perform_job(Picture, args(identity))

    refute_received :picture_requested
    assert %{avatar_source: :directory, avatar_etag: "graph"} = reload(identity)
    assert blobs(store) == %{blob_name(identity) => {png(), "image/jpeg"}}
  end

  test "deletes the photo when the claim is gone", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: nil, avatar_source: :picture, avatar_etag: "sha")
    put_blob(store, blob_name(identity), jpeg())

    assert :ok = perform_job(Picture, args(identity))

    assert %{avatar_source: nil, avatar_etag: nil} = reload(identity)
    assert blobs(store) == %{}
  end

  test "deletes the photo when the URL is gone", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: @url, avatar_source: :picture, avatar_etag: "sha")
    put_blob(store, blob_name(identity), jpeg())
    stub_picture(404, "")

    assert :ok = perform_job(Picture, args(identity))

    assert %{avatar_etag: nil} = reload(identity)
    assert blobs(store) == %{}
  end

  test "ignores a URL that is not HTTPS", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: "http://idp.example.com/photo.jpg")
    stub_picture(200, jpeg())

    assert :ok = perform_job(Picture, args(identity))

    refute_received :picture_requested
    assert blobs(store) == %{}
  end

  test "refuses a URL that points at a private address", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: "https://169.254.169.254/photo.jpg")
    stub_picture(200, jpeg())

    assert :ok = perform_job(Picture, args(identity))

    refute_received :picture_requested
    assert blobs(store) == %{}
  end

  test "skips a photo that is not an image", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: @url)
    stub_picture(200, "<html>sign in</html>")

    assert :ok = perform_job(Picture, args(identity))

    assert %{avatar_etag: nil} = reload(identity)
    assert blobs(store) == %{}
  end

  test "skips a photo over the size limit", %{account: account, store: store} do
    identity = identity_fixture(account: account, picture: @url)
    stub_picture(200, jpeg() <> :binary.copy("x", Portal.Avatars.max_bytes()))

    assert :ok = perform_job(Picture, args(identity))

    assert blobs(store) == %{}
  end

  test "retries a server error later", %{account: account} do
    identity = identity_fixture(account: account, picture: @url)
    stub_picture(503, "")

    assert {:error, {:unexpected_status, 503}} = perform_job(Picture, args(identity))
  end

  describe "enqueue/1" do
    test "queues a job for an identity with a picture", %{account: account} do
      identity = identity_fixture(account: account, picture: @url)

      assert :ok = Picture.enqueue(identity)

      assert_enqueued(worker: Picture, args: %{identity_id: identity.id, picture: @url})
    end

    test "queues a job to delete a sign-in photo whose claim is gone", %{account: account} do
      identity = identity_fixture(account: account, picture: nil, avatar_source: :picture, avatar_etag: "sha")

      assert :ok = Picture.enqueue(identity)

      assert_enqueued(worker: Picture, args: %{identity_id: identity.id})
    end

    test "queues nothing without a picture", %{account: account} do
      identity = identity_fixture(account: account, picture: nil)

      assert :ok = Picture.enqueue(identity)

      refute_enqueued(worker: Picture)
    end

    test "runs the same URL at most once a day", %{account: account} do
      identity = identity_fixture(account: account, picture: @url)

      assert :ok = Picture.enqueue(identity)
      assert :ok = Picture.enqueue(identity)
      assert :ok = Picture.enqueue(%{identity | picture: @url <> "?v=2"})

      assert [_first, _changed_url] = all_enqueued(worker: Picture)
    end
  end

  defp args(identity), do: %{account_id: identity.account_id, identity_id: identity.id, picture: identity.picture}

  defp reload(identity), do: Repo.get_by!(ExternalIdentity, account_id: identity.account_id, id: identity.id)

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp stub_picture(status, body) do
    test_pid = self()

    Req.Test.stub(Picture, fn conn ->
      send(test_pid, :picture_requested)
      Plug.Conn.send_resp(conn, status, body)
    end)
  end
end
