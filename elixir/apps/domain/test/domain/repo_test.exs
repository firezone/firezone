defmodule Domain.RepoTest do
  use Domain.DataCase, async: true
  import Domain.Repo

  describe "fetch/3" do
    test "returns {:ok, schema} when a single result is found" do
      account = Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      assert fetch(queryable, query_module) == {:ok, account}
    end

    test "allows to preload deeply nested fields" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_userpass_provider(account: account)
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account)
      Fixtures.Policies.create_policy(account: account)

      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert {:ok, account} =
               fetch(queryable, query_module,
                 preload: [
                   :legacy_auth_providers,
                   policies: [],
                   actors: [identities: :provider],
                   clients: [:online?, :actor]
                 ]
               )

      assert Ecto.assoc_loaded?(account.legacy_auth_providers)

      assert Ecto.assoc_loaded?(account.policies)

      assert Ecto.assoc_loaded?(account.actors)
      assert Enum.all?(account.actors, &Ecto.assoc_loaded?(&1.identities))

      assert Ecto.assoc_loaded?(account.clients)
      assert Enum.all?(account.clients, &(&1.online? == false))
      assert Enum.all?(account.clients, &Ecto.assoc_loaded?(&1.actor))
    end

    test "allows to use filters" do
      account = Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert {:ok, _account} = fetch(queryable, query_module, filter: [slug: account.slug])
      assert fetch(queryable, query_module, filter: [slug: "foo"]) == {:error, :not_found}
    end

    test "raises when the query returns more than one row" do
      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert_raise Ecto.MultipleResultsError, fn ->
        fetch(queryable, query_module)
      end
    end

    test "returns {:error, :not_found} when no results are found" do
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert fetch(queryable, query_module) == {:error, :not_found}
    end
  end

  describe "fetch_and_update/3" do
    test "returns updated schema for a single updated record" do
      account = Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      new_value = Ecto.UUID.generate()
      changeset_cb = fn account -> Ecto.Changeset.change(account, name: new_value) end

      assert {:ok, updated_account} =
               fetch_and_update(queryable, query_module, with: changeset_cb)

      assert updated_account.id == account.id
      assert updated_account.name == new_value
    end

    test "raises when the query returns more than one row" do
      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      changeset_cb = fn account -> Ecto.Changeset.change(account, name: "foo") end

      assert_raise Ecto.MultipleResultsError, fn ->
        fetch_and_update(queryable, query_module, with: changeset_cb)
      end
    end

    test "returns {:error, :not_found} when no results are found" do
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      changeset_cb = fn account -> Ecto.Changeset.change(account, name: "foo") end
      assert fetch_and_update(queryable, query_module, with: changeset_cb) == {:error, :not_found}
    end

    test "returns {:error, changeset} when changeset is invalid" do
      Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      changeset_cb = fn account ->
        account
        |> Ecto.Changeset.change(name: "foo")
        |> Ecto.Changeset.add_error(:name, "is invalid")
      end

      assert {:error, %Ecto.Changeset{}} =
               fetch_and_update(queryable, query_module, with: changeset_cb)
    end

    test "allows to execute a callback after transaction is committed" do
      Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      test_pid = self()

      broadcast = fn account ->
        send(test_pid, {:broadcast, account})
        :ok
      end

      assert {:ok, updated_account} =
               fetch_and_update(queryable, query_module,
                 with: &Ecto.Changeset.change(&1, name: Ecto.UUID.generate()),
                 after_commit: broadcast
               )

      assert_receive {:broadcast, ^updated_account}

      assert {:ok, updated_account} =
               fetch_and_update(queryable, query_module,
                 with: &Ecto.Changeset.change(&1, name: Ecto.UUID.generate()),
                 after_commit: fn account, _changeset -> broadcast.(account) end
               )

      assert_receive {:broadcast, ^updated_account}
    end

    test "allows to preload deeply nested fields" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_userpass_provider(account: account)
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account)
      Fixtures.Policies.create_policy(account: account)

      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      new_value = Ecto.UUID.generate()
      changeset_cb = fn account -> Ecto.Changeset.change(account, name: new_value) end

      assert {:ok, updated_account} =
               fetch_and_update(queryable, query_module,
                 with: changeset_cb,
                 preload: [
                   :legacy_auth_providers,
                   policies: [],
                   actors: [identities: :provider],
                   clients: [:online?, :actor]
                 ]
               )

      assert Ecto.assoc_loaded?(updated_account.legacy_auth_providers)

      assert Ecto.assoc_loaded?(updated_account.policies)

      assert Ecto.assoc_loaded?(updated_account.actors)
      assert Enum.all?(updated_account.actors, &Ecto.assoc_loaded?(&1.identities))

      assert Ecto.assoc_loaded?(updated_account.clients)
      assert Enum.all?(updated_account.clients, &(&1.online? == false))
      assert Enum.all?(updated_account.clients, &Ecto.assoc_loaded?(&1.actor))
    end

    test "allows to use filters" do
      account = Fixtures.Accounts.create_account()
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()
      new_value = Ecto.UUID.generate()
      changeset_cb = fn account -> Ecto.Changeset.change(account, name: new_value) end

      assert {:ok, _updated_account} =
               fetch_and_update(queryable, query_module,
                 with: changeset_cb,
                 filter: [slug: account.slug]
               )

      assert fetch_and_update(queryable, query_module,
               with: changeset_cb,
               filter: [slug: "foo"]
             ) == {:error, :not_found}
    end
  end

  describe "list/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      query_module = Domain.Actors.Actor.Query
      queryable = query_module.all()

      %{account: account, query_module: query_module, queryable: queryable}
    end

    test "returns empty list when there are no results", %{
      query_module: query_module,
      queryable: queryable
    } do
      empty_metadata = %Domain.Repo.Paginator.Metadata{limit: 50, count: 0}

      assert list(queryable, query_module) == {:ok, [], empty_metadata}
      assert list(queryable, query_module, limit: 1000) == {:ok, [], empty_metadata}
      assert list(queryable, query_module, limit: 1) == {:ok, [], empty_metadata}
      assert list(queryable, query_module, limit: -1) == {:ok, [], empty_metadata}
    end

    test "returns single result if only one record exists", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      actor = Fixtures.Actors.create_actor(account: account)

      assert {:ok, [returned_actor], _metadata} = list(queryable, query_module)
      assert returned_actor.id == actor.id
    end

    test "allows to preload deeply nested fields" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_userpass_provider(account: account)
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Clients.create_client(account: account)
      Fixtures.Policies.create_policy(account: account)

      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert {:ok, accounts, _metadata} =
               list(queryable, query_module,
                 preload: [
                   :legacy_auth_providers,
                   policies: [],
                   actors: [identities: :provider],
                   clients: [:online?, :actor]
                 ]
               )

      for account <- accounts do
        assert Ecto.assoc_loaded?(account.legacy_auth_providers)

        assert Ecto.assoc_loaded?(account.policies)

        assert Ecto.assoc_loaded?(account.actors)
        assert Enum.all?(account.actors, &Ecto.assoc_loaded?(&1.identities))

        assert Ecto.assoc_loaded?(account.clients)
        assert Enum.all?(account.clients, &(&1.online? == false))
        assert Enum.all?(account.clients, &Ecto.assoc_loaded?(&1.actor))
      end
    end

    test "allows to set custom order", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      dt1 = ~U[2000-01-01 00:00:00.000000Z]
      dt2 = ~U[2000-01-02 00:00:00.000000Z]

      Fixtures.Actors.create_actor(account: account)
      |> Fixtures.Actors.update(deleted_at: dt1)

      Fixtures.Actors.create_actor(account: account)
      |> Fixtures.Actors.update(deleted_at: dt2)

      assert {:ok, [%{deleted_at: ^dt1}, %{deleted_at: ^dt2}], _metadata} =
               list(queryable, query_module, order_by: [{:actors, :asc, :deleted_at}])

      assert {:ok, [%{deleted_at: ^dt2}, %{deleted_at: ^dt1}], _metadata} =
               list(queryable, query_module, order_by: [{:actors, :desc, :deleted_at}])
    end

    test "allows to filter results" do
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      account1 = Fixtures.Accounts.create_account(name: "Josh Account")
      account2 = Fixtures.Accounts.create_account(name: "Jon's Account")
      account3 = Fixtures.Accounts.create_account(name: "Somebody Else Account")

      assert {:ok, [^account1], _metadata} =
               list(queryable, query_module, filter: [slug: account1.slug])

      assert {:ok, [^account3], _metadata} =
               list(queryable, query_module, filter: [name: "Some"])

      assert {:ok, [^account2], _metadata} =
               list(queryable, query_module, filter: [name: "jon"])

      assert {:ok, accounts, _metadata} =
               list(queryable, query_module,
                 filter: [
                   {:or,
                    [
                      [name: "Some"],
                      [name: "jon"]
                    ]}
                 ]
               )

      account_ids = Enum.map(accounts, & &1.id)
      assert length(accounts) == 2
      assert account2.id in account_ids
      assert account3.id in account_ids

      assert {:ok, [^account1], _metadata} =
               list(queryable, query_module,
                 filter: [
                   {:and,
                    [
                      [name: "Josh"],
                      [name: "Acc"]
                    ]}
                 ]
               )
    end

    test "returns error on unknown filter", %{
      query_module: query_module,
      queryable: queryable
    } do
      assert list(queryable, query_module, filter: [unknown: "foo"]) ==
               {:error, {:unknown_filter, name: :unknown}}
    end

    test "returns error on invalid filter type" do
      query_module = Domain.Accounts.Account.Query
      queryable = query_module.all()

      assert list(queryable, query_module, filter: [name: 1]) ==
               {:error, {:invalid_type, type: :string, value: 1}}
    end

    test "returns up to 50 items by default", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      for _ <- 1..60, do: Fixtures.Actors.create_actor(account: account)

      assert {:ok, actors, metadata} = list(queryable, query_module)
      assert length(actors) == 50
      assert metadata.limit == 50
    end

    test "accept page size limit that is smaller than the results set", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_actor(account: account)

      for limit <- [1, 2] do
        assert {:ok, actors, metadata} = list(queryable, query_module, page: [limit: limit])
        assert length(actors) == limit
        assert metadata.limit == limit
        assert metadata.next_page_cursor
        refute metadata.previous_page_cursor
      end
    end

    test "accept page size limit that is greater than the results set", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_actor(account: account)
      Fixtures.Actors.create_actor(account: account)

      # when limit is greater that results set
      assert {:ok, actors, metadata} = list(queryable, query_module, page: [limit: 5])

      assert length(actors) == 3
      assert metadata.limit == 5
      refute metadata.next_page_cursor
      refute metadata.previous_page_cursor
    end

    test "page size cannot be bigger than 100", %{
      query_module: query_module,
      queryable: queryable
    } do
      assert {:ok, [], metadata} = list(queryable, query_module, page: [limit: 200])

      assert metadata.limit == 100
    end

    test "page size cannot be less than 1", %{
      query_module: query_module,
      queryable: queryable
    } do
      assert {:ok, [], metadata} = list(queryable, query_module, page: [limit: -1])
      assert metadata.limit == 1

      assert {:ok, [], metadata} = list(queryable, query_module, page: [limit: 0])
      assert metadata.limit == 1
    end

    test "cursor can be used to load the next and previous pages", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      fixed_datetime = ~U[2000-01-01 00:00:00.000000Z]

      actors =
        for i <- 1..10 do
          # we need this to make sure that if timestamps collapse we still can paginate using ids
          add_seconds = if rem(i, 2) == 0, do: i, else: i - 1
          inserted_at = DateTime.add(fixed_datetime, add_seconds, :second)

          Fixtures.Actors.create_actor(account: account)
          |> Fixtures.Actors.update(inserted_at: inserted_at)
        end

      actors = Enum.sort_by(actors, &{&1.inserted_at, &1.id})

      ids = Enum.map(actors, & &1.id)
      {first_page_ids, rest_ids} = Enum.split(ids, 4)
      {second_page_ids, rest_ids} = Enum.split(rest_ids, 4)
      {third_page_ids, []} = Enum.split(rest_ids, 2)

      # load first page with 4 entries
      assert {:ok, actors1, metadata1} = list(queryable, query_module, page: [limit: 4])

      assert Enum.map(actors1, & &1.id) == first_page_ids
      assert metadata1.limit == 4
      assert metadata1.next_page_cursor
      refute metadata1.previous_page_cursor

      # load next page with 4 more entries
      assert {:ok, actors2, metadata2} =
               list(queryable, query_module, page: [limit: 4, cursor: metadata1.next_page_cursor])

      assert Enum.map(actors2, & &1.id) == second_page_ids
      assert metadata2.limit == 4
      assert metadata2.next_page_cursor
      assert metadata2.previous_page_cursor

      # load next page with 2 more entries
      assert {:ok, actors3, metadata3} =
               list(queryable, query_module, page: [limit: 4, cursor: metadata2.next_page_cursor])

      assert Enum.map(actors3, & &1.id) == third_page_ids
      assert metadata3.limit == 4
      refute metadata3.next_page_cursor
      assert metadata3.previous_page_cursor

      # go back to 2nd page
      assert {:ok, actors4, metadata4} =
               list(queryable, query_module,
                 page: [limit: 4, cursor: metadata3.previous_page_cursor]
               )

      assert Enum.map(actors4, & &1.id) == second_page_ids
      assert metadata4.limit == 4
      assert metadata4.next_page_cursor
      assert metadata4.previous_page_cursor

      # go back to first page
      assert {:ok, actors4, metadata4} =
               list(queryable, query_module,
                 page: [limit: 4, cursor: metadata4.previous_page_cursor]
               )

      assert Enum.map(actors4, & &1.id) == first_page_ids
      assert metadata4.limit == 4
      assert metadata4.next_page_cursor
      refute metadata4.previous_page_cursor
    end

    test "cursors work with the custom ordering", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      fixed_datetime = ~U[2000-01-01 00:00:00.000000Z]

      actors =
        for i <- 1..10 do
          last_synced_at = DateTime.add(fixed_datetime, i, :second)

          Fixtures.Actors.create_actor(account: account)
          |> Fixtures.Actors.update(last_synced_at: last_synced_at)
        end

      actors = actors |> Enum.sort_by(&{&1.last_synced_at, &1.id}) |> Enum.reverse()

      ids = Enum.map(actors, & &1.id)
      {first_page_ids, rest_ids} = Enum.split(ids, 4)
      {second_page_ids, rest_ids} = Enum.split(rest_ids, 4)
      {third_page_ids, []} = Enum.split(rest_ids, 2)

      # load first page with 4 entries
      assert {:ok, actors1, metadata1} =
               list(queryable, query_module,
                 order_by: [{:actors, :desc, :last_synced_at}],
                 page: [limit: 4]
               )

      assert Enum.map(actors1, & &1.id) == first_page_ids
      assert metadata1.limit == 4
      assert metadata1.next_page_cursor
      refute metadata1.previous_page_cursor

      # load next page with 4 more entries
      assert {:ok, actors2, metadata2} =
               list(queryable, query_module,
                 order_by: [{:actors, :desc, :last_synced_at}],
                 page: [limit: 4, cursor: metadata1.next_page_cursor]
               )

      assert Enum.map(actors2, & &1.id) == second_page_ids
      assert metadata2.limit == 4
      assert metadata2.next_page_cursor
      assert metadata2.previous_page_cursor

      # load next page with 2 more entries
      assert {:ok, actors3, metadata3} =
               list(queryable, query_module,
                 order_by: [{:actors, :desc, :last_synced_at}],
                 page: [limit: 4, cursor: metadata2.next_page_cursor]
               )

      assert Enum.map(actors3, & &1.id) == third_page_ids
      assert metadata3.limit == 4
      refute metadata3.next_page_cursor
      assert metadata3.previous_page_cursor

      # go back to 2nd page
      assert {:ok, actors4, metadata4} =
               list(queryable, query_module,
                 order_by: [{:actors, :desc, :last_synced_at}],
                 page: [limit: 4, cursor: metadata3.previous_page_cursor]
               )

      assert Enum.map(actors4, & &1.id) == second_page_ids
      assert metadata4.limit == 4
      assert metadata4.next_page_cursor
      assert metadata4.previous_page_cursor

      # go back to first page
      assert {:ok, actors4, metadata4} =
               list(queryable, query_module,
                 order_by: [{:actors, :desc, :last_synced_at}],
                 page: [limit: 4, cursor: metadata4.previous_page_cursor]
               )

      assert Enum.map(actors4, & &1.id) == first_page_ids
      assert metadata4.limit == 4
      assert metadata4.next_page_cursor
      refute metadata4.previous_page_cursor
    end

    test "cursor paging works when all entries are returned on the first page", %{
      account: account,
      query_module: query_module,
      queryable: queryable
    } do
      fixed_datetime = ~U[2000-01-01 00:00:00.000000Z]

      ids =
        for i <- 1..10 do
          inserted_at = DateTime.add(fixed_datetime, i, :second)

          actor =
            Fixtures.Actors.create_actor(account: account)
            |> Fixtures.Actors.update(inserted_at: inserted_at)

          actor.id
        end

      assert {:ok, actors, metadata} = list(queryable, query_module, page: [limit: 10])

      assert Enum.map(actors, & &1.id) == ids
      assert metadata.limit == 10
      refute metadata.next_page_cursor
      refute metadata.previous_page_cursor
    end

    test "cursor paging works when there are no results", %{
      query_module: query_module,
      queryable: queryable
    } do
      cursor_fields = query_module.cursor_fields()

      cursor =
        Domain.Repo.Paginator.encode_cursor(:after, cursor_fields, %{
          id: Ecto.UUID.generate(),
          inserted_at: ~U[2000-01-01 00:00:00.000000Z]
        })

      assert {:ok, [], metadata} = list(queryable, query_module, page: [cursor: cursor])

      refute metadata.next_page_cursor
      refute metadata.previous_page_cursor
    end

    test "returns error on invalid cursor", %{
      query_module: query_module,
      queryable: queryable
    } do
      cursor_fields = query_module.cursor_fields()

      cursor =
        Domain.Repo.Paginator.encode_cursor(:after, cursor_fields, %{
          id: Ecto.UUID.generate(),
          inserted_at: nil
        })

      assert list(queryable, query_module, page: [cursor: cursor]) ==
               {:error, :invalid_cursor}

      assert list(queryable, query_module, page: [cursor: "foo"]) ==
               {:error, :invalid_cursor}

      assert list(queryable, query_module, page: [cursor: 1]) ==
               {:error, :invalid_cursor}
    end
  end
end
