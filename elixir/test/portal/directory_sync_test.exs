defmodule Portal.DirectorySyncTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures

  alias Portal.DirectorySync
  alias Portal.DirectorySync.GroupState
  alias Portal.DirectorySync.IdentityState
  alias Portal.ExternalIdentity
  alias Portal.Group
  alias Portal.Membership

  setup do
    account = account_fixture(features: %{idp_sync: true})
    entra_directory = entra_directory_fixture(account: account)
    directory = Repo.get_by!(Portal.Directory, id: entra_directory.id, account_id: account.id)
    issuer = "https://login.microsoftonline.com/#{entra_directory.tenant_id}/v2.0"

    now = DateTime.utc_now()

    %{
      account: account,
      directory: directory,
      issuer: issuer,
      sync_start: DateTime.add(now, -60, :second),
      webhook_at: now,
      later: DateTime.add(now, 60, :second)
    }
  end

  describe "identities" do
    test "a full sync page from before a webhook removal cannot bring the user back", ctx do
      identity = directory_identity(ctx, "user-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {1, nil} =
               DirectorySync.remove_identity(ctx.account.id, ctx.directory.id, identity, ctx.webhook_at)

      refute Repo.get_by(ExternalIdentity, id: identity.id)

      assert {:ok, %{upserted_identities: 0}} =
               upsert_identities(ctx, ctx.sync_start, [identity_attrs("user-1")])

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1", account_id: ctx.account.id)

      assert {:ok, %{upserted_identities: 1}} =
               upsert_identities(ctx, ctx.later, [identity_attrs("user-1")])

      assert Repo.get_by(ExternalIdentity, idp_id: "user-1", account_id: ctx.account.id)
    end

    test "a removal older than the newest write is skipped", ctx do
      identity = directory_identity(ctx, "user-1", ctx.later)

      assert {0, nil} =
               DirectorySync.remove_identity(ctx.account.id, ctx.directory.id, identity, ctx.webhook_at)

      assert Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "the cleanup leaves a tombstone that blocks writes from before the run", ctx do
      identity = directory_identity(ctx, "user-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {1, nil} =
               DirectorySync.delete_unsynced_identities(
                 ctx.account.id,
                 ctx.directory.id,
                 ctx.sync_start
               )

      refute Repo.get_by(ExternalIdentity, id: identity.id)

      tombstone = state(IdentityState, ctx, "user-1")
      assert DateTime.compare(tombstone.synced_at, ctx.sync_start) == :eq

      assert {:ok, %{upserted_identities: 0}} =
               upsert_identities(
                 ctx,
                 DateTime.add(ctx.sync_start, -1, :second),
                 [identity_attrs("user-1")]
               )

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1", account_id: ctx.account.id)

      assert {:ok, %{upserted_identities: 1}} =
               upsert_identities(ctx, ctx.webhook_at, [identity_attrs("user-1")])

      assert Repo.get_by(ExternalIdentity, idp_id: "user-1", account_id: ctx.account.id)
    end
  end

  describe "groups" do
    test "a full sync page from before a webhook removal cannot bring the group back", ctx do
      group = directory_group(ctx, "group-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {1, nil} =
               DirectorySync.remove_group(ctx.account.id, ctx.directory.id, group, ctx.webhook_at)

      refute Repo.get_by(Group, id: group.id)

      assert {:ok, %{upserted_groups: 0}} =
               DirectorySync.batch_upsert_groups(
                 ctx.account.id,
                 ctx.directory.id,
                 ctx.sync_start,
                 [%{idp_id: "group-1", name: "Group 1"}],
                 :group
               )

      refute Repo.get_by(Group, idp_id: "group-1", account_id: ctx.account.id)

      assert {:ok, %{upserted_groups: 1}} =
               DirectorySync.batch_upsert_groups(
                 ctx.account.id,
                 ctx.directory.id,
                 ctx.later,
                 [%{idp_id: "group-1", name: "Group 1"}],
                 :group
               )

      assert Repo.get_by(Group, idp_id: "group-1", account_id: ctx.account.id)
    end
  end

  describe "memberships" do
    test "a group member list rewrite blocks membership writes from before it", ctx do
      directory_group(ctx, "group-1", DateTime.add(ctx.sync_start, -3600, :second))
      identity = directory_identity(ctx, "user-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {:ok, _} =
               DirectorySync.batch_upsert_groups(
                 ctx.account.id,
                 ctx.directory.id,
                 ctx.webhook_at,
                 [%{idp_id: "group-1", name: "Group 1"}],
                 :group
               )

      assert {:ok, %{upserted_memberships: 0}} =
               upsert_memberships(ctx, ctx.sync_start, [{"group-1", "user-1"}])

      refute Repo.get_by(Membership, actor_id: identity.actor_id)

      assert {:ok, %{upserted_memberships: 1}} =
               upsert_memberships(ctx, ctx.webhook_at, [{"group-1", "user-1"}])

      assert Repo.get_by(Membership, actor_id: identity.actor_id)
    end

    test "a user membership list rewrite blocks membership writes from before it", ctx do
      directory_group(ctx, "group-1", DateTime.add(ctx.sync_start, -3600, :second))
      identity = directory_identity(ctx, "user-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {1, nil} =
               DirectorySync.stamp_identity_memberships(
                 ctx.account.id,
                 ctx.directory.id,
                 "user-1",
                 ctx.webhook_at
               )

      assert {:ok, %{upserted_memberships: 0}} =
               upsert_memberships(ctx, ctx.sync_start, [{"group-1", "user-1"}])

      refute Repo.get_by(Membership, actor_id: identity.actor_id)

      assert {:ok, %{upserted_memberships: 1}} =
               upsert_memberships(ctx, ctx.later, [{"group-1", "user-1"}])

      assert Repo.get_by(Membership, actor_id: identity.actor_id)
    end

    test "removing a user stamps their membership list", ctx do
      directory_group(ctx, "group-1", DateTime.add(ctx.sync_start, -3600, :second))
      identity = directory_identity(ctx, "user-1", DateTime.add(ctx.sync_start, -3600, :second))

      assert {1, nil} =
               DirectorySync.remove_identity(ctx.account.id, ctx.directory.id, identity, ctx.webhook_at)

      assert {:ok, _} = upsert_identities(ctx, ctx.later, [identity_attrs("user-1")])

      assert {:ok, %{upserted_memberships: 0}} =
               upsert_memberships(ctx, ctx.sync_start, [{"group-1", "user-1"}])

      assert {:ok, %{upserted_memberships: 1}} =
               upsert_memberships(ctx, ctx.later, [{"group-1", "user-1"}])
    end
  end

  describe "prune_tombstones/3" do
    test "drops only dead state rows older than the previous run", ctx do
      live = directory_identity(ctx, "live", DateTime.add(ctx.sync_start, -7200, :second))
      tombstone(IdentityState, ctx, "old-dead", DateTime.add(ctx.sync_start, -7200, :second))
      tombstone(IdentityState, ctx, "new-dead", ctx.webhook_at)
      tombstone(GroupState, ctx, "old-group", DateTime.add(ctx.sync_start, -7200, :second))

      assert :ok = DirectorySync.prune_tombstones(ctx.account.id, ctx.directory.id, ctx.sync_start)

      assert state(IdentityState, ctx, live.idp_id)
      refute Repo.get_by(IdentityState, directory_id: ctx.directory.id, idp_id: "old-dead")
      assert state(IdentityState, ctx, "new-dead")
      refute Repo.get_by(GroupState, directory_id: ctx.directory.id, idp_id: "old-group")
    end
  end

  defp directory_identity(ctx, idp_id, synced_at) do
    actor = actor_fixture(account: ctx.account, email: "#{idp_id}@example.com")

    identity_fixture(
      account: ctx.account,
      actor: actor,
      directory: ctx.directory,
      issuer: ctx.issuer,
      idp_id: idp_id,
      email: "#{idp_id}@example.com",
      synced_at: synced_at
    )
  end

  defp directory_group(ctx, idp_id, synced_at) do
    group_fixture(account: ctx.account, directory: ctx.directory, idp_id: idp_id, synced_at: synced_at)
  end

  defp identity_attrs(idp_id) do
    %{
      idp_id: idp_id,
      email: "#{idp_id}@example.com",
      name: idp_id,
      given_name: nil,
      family_name: nil,
      preferred_username: "#{idp_id}@example.com",
      profile: nil
    }
  end

  defp upsert_identities(ctx, synced_at, attrs) do
    DirectorySync.batch_upsert_identities(
      ctx.account.id,
      ctx.issuer,
      ctx.directory.id,
      synced_at,
      attrs,
      [:profile]
    )
  end

  defp upsert_memberships(ctx, synced_at, tuples) do
    DirectorySync.batch_upsert_memberships(
      ctx.account.id,
      ctx.issuer,
      ctx.directory.id,
      synced_at,
      tuples
    )
  end

  defp state(schema, ctx, idp_id) do
    Repo.get_by!(schema, account_id: ctx.account.id, directory_id: ctx.directory.id, idp_id: idp_id)
  end

  defp tombstone(schema, ctx, idp_id, synced_at) do
    Repo.insert!(
      struct(schema,
        account_id: ctx.account.id,
        directory_id: ctx.directory.id,
        idp_id: idp_id,
        synced_at: synced_at
      )
    )
  end
end
