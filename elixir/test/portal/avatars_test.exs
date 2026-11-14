defmodule Portal.AvatarsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AvatarStorageHelpers
  import Portal.IdentityFixtures

  alias Portal.Avatars

  setup do
    %{account: account_fixture(), store: stub_avatar_storage()}
  end

  describe "prune/0" do
    test "deletes the blobs that no identity links to", %{account: account, store: store} do
      current = identity_fixture(account: account, avatar_source: :picture, avatar_etag: "v2")
      gone = identity_fixture(account: account, avatar_source: :picture, avatar_etag: "v1")
      Repo.delete!(gone)
      put_blob(store, blob_name(current), jpeg())
      put_blob(store, blob_name(current, "v1"), jpeg())
      put_blob(store, blob_name(gone), jpeg())
      put_blob(store, "#{Ecto.UUID.generate()}/#{Ecto.UUID.generate()}/abc", jpeg())
      put_blob(store, "not-a-photo", jpeg())

      assert :ok = Avatars.prune()

      assert Map.keys(blobs(store)) == [blob_name(current)]
    end

    test "keeps blobs that may belong to a photo being saved", %{account: account, store: store} do
      identity = identity_fixture(account: account)
      put_blob(store, blob_name(identity, "new"), jpeg(), modified_at: DateTime.utc_now())

      assert :ok = Avatars.prune()

      assert Map.keys(blobs(store)) == [blob_name(identity, "new")]
    end

    test "runs from the cron worker", %{account: account, store: store} do
      put_blob(store, "#{account.id}/#{Ecto.UUID.generate()}/abc", jpeg())

      assert :ok = perform_job(Avatars.Prune, %{})

      assert blobs(store) == %{}
    end
  end

  describe "delete_account/1" do
    test "deletes every photo of the account and no other", %{account: account, store: store} do
      identity = identity_fixture(account: account, avatar_source: :picture, avatar_etag: "v1")
      other = identity_fixture(account: account_fixture(), avatar_source: :picture, avatar_etag: "v1")
      put_blob(store, blob_name(identity), jpeg(), modified_at: DateTime.utc_now())
      put_blob(store, blob_name(other), jpeg())

      assert :ok = perform_job(Avatars.DeleteAccount, %{account_id: account.id})

      assert Map.keys(blobs(store)) == [blob_name(other)]
    end

    test "is queued when an account is deleted", %{account: account} do
      {:ok, account} = account |> Ecto.Changeset.change(is_disabled: true) |> Repo.update()

      assert :ok = Portal.Ops.delete_disabled_account(account.id)

      assert_enqueued(worker: Avatars.DeleteAccount, args: %{account_id: account.id})
    end

    test "is not queued when photos are off", %{account: account} do
      Portal.Config.put_env_override(:avatars_container_url, nil)
      {:ok, account} = account |> Ecto.Changeset.change(is_disabled: true) |> Repo.update()

      assert :ok = Portal.Ops.delete_disabled_account(account.id)

      refute_enqueued(worker: Avatars.DeleteAccount)
    end
  end

  describe "put_actor_avatar/1" do
    test "prefers a directory photo over a newer sign-in photo", %{account: account} do
      actor = actor_fixture(account: account)
      directory = identity_fixture(account: account, actor: actor, avatar_source: :directory, avatar_etag: "graph")
      identity_fixture(account: account, actor: actor, avatar_source: :picture, avatar_etag: "sha")

      assert %{avatar_identity_id: id, avatar_etag: "graph"} = Avatars.put_actor_avatar(actor)
      assert id == directory.id
    end

    test "leaves an actor without a photo alone", %{account: account} do
      actor = actor_fixture(account: account)

      assert %{avatar_identity_id: nil, avatar_etag: nil} = Avatars.put_actor_avatar(actor)
    end
  end
end
