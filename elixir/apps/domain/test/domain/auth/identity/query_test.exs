defmodule Domain.Auth.Identity.QueryTest do
  use Domain.DataCase, async: true
  alias Domain.{Actors, Repo}
  alias Domain.Auth.Identity

  describe "batch_upsert/4" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{
        account: account,
        provider: provider
      }
    end

    test "returns {:ok, %{upserted_identities: 0}} for empty list", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      assert Identity.Query.batch_upsert(account.id, provider.id, now, []) ==
               {:ok, %{upserted_identities: 0}}

      assert Repo.aggregate(Identity, :count) == 0
      assert Repo.aggregate(Actors.Actor, :count) == 0
    end

    test "creates new identities and actors when they don't exist", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      attrs_list = [
        %{
          name: "User 1",
          provider_identifier: "user-001",
          email: "user1@example.com"
        },
        %{
          name: "User 2",
          provider_identifier: "user-002",
          email: "user2@example.com"
        }
      ]

      assert {:ok, %{upserted_identities: 2}} =
               Identity.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      # Verify identities were created
      identities =
        Identity.Query.all()
        |> Identity.Query.by_account_id(account.id)
        |> Identity.Query.by_provider_id(provider.id)
        |> Repo.all()
        |> Repo.preload(:actor)

      assert length(identities) == 2

      for identity <- identities do
        assert identity.actor.type == :account_user
        assert identity.provider_id == provider.id
        assert identity.account_id == account.id
        assert identity.last_synced_at == now
        assert identity.provider_identifier in ["user-001", "user-002"]
        assert identity.email in ["user1@example.com", "user2@example.com"]
        assert identity.actor.name in ["User 1", "User 2"]
        assert identity.actor.last_synced_at == now
        assert identity.created_by == :provider
      end

      # Verify correct counts
      assert Repo.aggregate(Identity, :count) == 2
      assert Repo.aggregate(Actors.Actor, :count) == 2
    end

    test "updates existing identities when they already exist", %{
      account: account,
      provider: provider
    } do
      now1 = DateTime.utc_now()
      now2 = DateTime.add(now1, 60, :second)

      # Create initial identity
      existing_actor =
        Fixtures.Actors.create_actor(
          account: account,
          type: :account_user,
          name: "Old Name"
        )

      existing_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "user-001",
          actor: existing_actor,
          email: "old@example.com"
        )

      # Update with new state
      attrs_list = [
        %{
          name: "New Name",
          provider_identifier: "user-001",
          email: "new@example.com"
        },
        %{
          name: "User 2",
          provider_identifier: "user-002",
          email: "user2@example.com"
        }
      ]

      {:ok, %{upserted_identities: 2}} =
        Identity.Query.batch_upsert(account.id, provider.id, now2, attrs_list)

      # Verify existing identity was updated
      updated_identity =
        Repo.get(Identity, existing_identity.id)
        |> Repo.preload(:actor)

      assert updated_identity.last_synced_at == now2
      assert updated_identity.email == "new@example.com"
      assert updated_identity.actor_id == existing_actor.id
      assert updated_identity.actor.name == "New Name"
      assert updated_identity.actor.last_synced_at == now2

      # Verify new identity was created
      new_identity =
        Identity.Query.all()
        |> Identity.Query.by_provider_identifier("user-002")
        |> Repo.one()
        |> Repo.preload(:actor)

      assert new_identity.id != existing_identity.id
      assert new_identity.email == "user2@example.com"
      assert new_identity.actor.name == "User 2"

      # Verify total count (1 updated, 1 new)
      assert Repo.aggregate(Identity, :count) == 2
      assert Repo.aggregate(Actors.Actor, :count) == 2
    end

    test "preserves identities from different providers", %{
      account: account,
      provider: provider
    } do
      {other_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      now = DateTime.utc_now()

      # Create an identity for another provider
      other_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: other_provider,
          provider_identifier: "other-user",
          actor: [type: :account_user, account: account]
        )

      # Batch upsert for our provider
      attrs_list = [
        %{
          name: "Our User",
          provider_identifier: "our-user",
          email: "our@example.com"
        }
      ]

      {:ok, %{upserted_identities: 1}} =
        Identity.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      # Verify other provider's identity is not affected
      assert Repo.get(Identity, other_identity.id)
      assert Repo.aggregate(Identity, :count) == 2
    end

    test "preserves identities from different accounts", %{
      provider: provider
    } do
      other_account = Fixtures.Accounts.create_account()
      now = DateTime.utc_now()

      # Create an identity for another account
      other_identity =
        Fixtures.Auth.create_identity(
          account: other_account,
          provider_provider_identifier: "user-001",
          actor: [type: :account_user, account: other_account]
        )

      # Batch upsert for our account
      attrs_list = [
        %{
          name: "User 1",
          provider_identifier: "user-001",
          email: "user1@example.com"
        }
      ]

      {:ok, %{upserted_identities: 1}} =
        Identity.Query.batch_upsert(provider.account_id, provider.id, now, attrs_list)

      # Verify other account's identity is not affected
      assert Repo.get(Identity, other_identity.id)
      assert Repo.aggregate(Identity, :count) == 2
    end

    test "handles special characters in names and emails", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      attrs_list = [
        %{
          name: "José María García-O'Brien",
          provider_identifier: "special-001",
          email: "josé+test@example.com"
        }
      ]

      assert {:ok, %{upserted_identities: 1}} =
               Identity.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      identity =
        Identity.Query.all()
        |> Identity.Query.by_provider_identifier("special-001")
        |> Repo.one()
        |> Repo.preload(:actor)

      assert identity.actor.name == "José María García-O'Brien"
      assert identity.email == "josé+test@example.com"
    end

    test "handles nil email", %{
      account: account,
      provider: provider
    } do
      now = DateTime.utc_now()

      attrs_list = [
        %{
          name: "User No Email",
          provider_identifier: "no-email-001",
          email: nil
        }
      ]

      assert {:ok, %{upserted_identities: 1}} =
               Identity.Query.batch_upsert(account.id, provider.id, now, attrs_list)

      identity =
        Identity.Query.all()
        |> Identity.Query.by_provider_identifier("no-email-001")
        |> Repo.one()
        |> Repo.preload(:actor)

      assert identity.actor.name == "User No Email"
      assert identity.email == nil
    end
  end
end
