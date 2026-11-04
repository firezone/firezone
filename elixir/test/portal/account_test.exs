defmodule Portal.AccountTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures

  alias Portal.Account

  alias Portal.Repo

  defp build_changeset(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug, :legal_name, :key])
    |> Account.changeset()
  end

  defp slug_rows(account) do
    import Ecto.Query

    Repo.all(
      from(s in Portal.AccountSlug,
        where: s.account_id == ^account.id,
        order_by: [asc: s.inserted_at]
      )
    )
  end

  describe "changeset/1 basic validations" do
    test "inserts name at maximum length" do
      account = account_fixture(name: String.duplicate("a", 64))
      assert String.length(account.name) == 64
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 65)})
      assert %{name: ["too long"]} = errors_on(changeset)
    end

    test "inserts slug at maximum length" do
      account = account_fixture(slug: String.duplicate("a", 100))
      assert String.length(account.slug) == 100
    end

    test "rejects slug exceeding maximum length" do
      changeset = build_changeset(%{slug: String.duplicate("a", 101)})
      assert %{slug: ["should be at most 100 character(s)"]} = errors_on(changeset)
    end

    test "inserts legal_name at maximum length" do
      account = account_fixture(legal_name: String.duplicate("a", 255))
      assert String.length(account.legal_name) == 255
    end

    test "rejects legal_name exceeding maximum length" do
      changeset = build_changeset(%{legal_name: String.duplicate("a", 256)})
      assert %{legal_name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 with the shared slug registry" do
    import Plug.Conn
    import Portal.SlugRegistryHelpers

    setup do
      use_azure_registry(:us)
      :ok
    end

    test "claims the slug in the registry before the local insert" do
      test_pid = self()

      stub_registry(fn
        %{method: "POST", request_path: "/slugs"} = conn ->
          send(test_pid, {:claimed, json_body(conn)})
          send_resp(conn, 204, "")
      end)

      account = account_fixture(slug: "claimed-first")

      assert_received {:claimed, %{"RowKey" => "claimed_first", "AccountId" => account_id, "Region" => "us"}}
      assert account_id == account.id
      assert [%Portal.AccountSlug{slug: "claimed-first"}] = slug_rows(account)
    end

    test "refuses a slug another region holds" do
      stub_registry(fn
        %{method: "POST"} = conn -> send_resp(conn, 409, "")
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("eu-owned", Ecto.UUID.generate(), "eu"))
      end)

      assert_raise Ecto.InvalidChangesetError, ~r/has already been taken/, fn ->
        account_fixture(slug: "eu-owned")
      end

      assert Repo.aggregate(Portal.AccountSlug, :count) == 0
    end

    test "refuses to create the account when the registry is unavailable" do
      stub_registry(fn conn -> send_resp(conn, 503, "") end)

      assert_raise Ecto.InvalidChangesetError, ~r/cannot be reserved right now/, fn ->
        account_fixture(slug: "unreachable")
      end
    end

    test "claims a changed slug and keeps the old one locally" do
      test_pid = self()

      stub_registry(fn
        %{method: "POST", request_path: "/slugs"} = conn ->
          send(test_pid, {:claimed, json_body(conn)["RowKey"]})
          send_resp(conn, 204, "")
      end)

      account = account_fixture(slug: "first-slug")
      account = update_account(account, slug: "second-slug")

      assert_received {:claimed, "first_slug"}
      assert_received {:claimed, "second_slug"}
      assert Enum.map(slug_rows(account), & &1.slug) == ["first-slug", "second-slug"]
    end
  end

  describe "changeset/1 slug registry" do
    test "registers the slug when the account is created" do
      account = account_fixture()

      assert [%Portal.AccountSlug{slug: slug}] = slug_rows(account)
      assert slug == account.slug
    end

    test "keeps the old slug when the slug changes" do
      account = account_fixture()
      old_slug = account.slug
      account = update_account(account, slug: "#{old_slug}_v2")

      assert Enum.map(slug_rows(account), & &1.slug) == [old_slug, "#{old_slug}_v2"]
    end

    test "does not add a row when the account switches back to an old slug" do
      account = account_fixture()
      old_slug = account.slug

      account =
        account
        |> update_account(slug: "#{old_slug}_v2")
        |> update_account(slug: old_slug)

      assert account.slug == old_slug
      assert Enum.map(slug_rows(account), & &1.slug) == [old_slug, "#{old_slug}_v2"]
    end

    test "rejects a slug that another account used before" do
      other = account_fixture()
      old_slug = other.slug
      update_account(other, slug: "#{old_slug}_v2")

      changeset =
        account_fixture()
        |> cast(%{slug: old_slug}, [:slug])
        |> Account.changeset()

      assert {:error, changeset} = Repo.update(changeset)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects a slug that another account uses now" do
      other = account_fixture()

      changeset =
        account_fixture()
        |> cast(%{slug: other.slug}, [:slug])
        |> Account.changeset()

      assert {:error, changeset} = Repo.update(changeset)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects the underscore twin of a hyphenated slug" do
      account_fixture(slug: "acme-corp")

      changeset =
        account_fixture()
        |> cast(%{slug: "acme_corp"}, [:slug])
        |> Account.changeset()

      assert {:error, changeset} = Repo.update(changeset)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "lets the owner of a hyphenated slug take the underscore twin" do
      account = account_fixture(slug: "acme-corp")

      changeset =
        account
        |> cast(%{slug: "acme_corp"}, [:slug])
        |> Account.changeset()

      assert {:ok, %{slug: "acme_corp"} = account} = Repo.update(changeset)
      assert [%{slug: "acme-corp"}, %{slug: "acme_corp"}] = slug_rows(account)
    end

    test "treats slugs case-insensitively" do
      other = account_fixture()

      changeset =
        account_fixture()
        |> cast(%{slug: String.upcase(other.slug)}, [:slug])
        |> Account.changeset()

      assert {:error, changeset} = Repo.update(changeset)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "removes the registry rows with the account" do
      account = account_fixture()
      Repo.delete!(account)

      assert slug_rows(account) == []
    end
  end

  describe "new_key/0" do
    test "returns a 6-character base-36 string" do
      key = Account.new_key()
      assert String.length(key) == 6
      assert key =~ ~r/^[a-z0-9]{6}$/
    end

    test "returns different values on successive calls" do
      keys = for _ <- 1..10, do: Account.new_key()
      assert length(Enum.uniq(keys)) > 1
    end
  end

  describe "iceless_enabled?/1" do
    test "returns true when the account feature flag is set" do
      account = %Account{features: %Portal.Accounts.Features{iceless: true}}
      assert Account.iceless_enabled?(account)
    end

    test "returns false when the account feature flag is disabled" do
      account = %Account{features: %Portal.Accounts.Features{iceless: false}}
      refute Account.iceless_enabled?(account)
    end

    test "returns false when the account feature flag is unset" do
      account = %Account{features: %Portal.Accounts.Features{}}
      refute Account.iceless_enabled?(account)
    end

    test "returns false when the account has no features" do
      account = %Account{features: nil}
      refute Account.iceless_enabled?(account)
    end
  end

  describe "account-local features" do
    test "log sinks does not require a global rollout flag" do
      account = %Account{features: %Portal.Accounts.Features{log_sinks: true}}
      assert Account.log_sinks_enabled?(account)
    end

    test "device posture requires only the account entitlement" do
      account = %Account{features: %Portal.Accounts.Features{device_posture: true}}
      assert Account.device_posture_enabled?(account)
    end

    test "device posture defaults to an unset account entitlement" do
      account = %Account{features: %Portal.Accounts.Features{}}

      assert account.features.device_posture == nil
      refute Account.device_posture_enabled?(account)
    end
  end

  describe "changeset/1 key validations" do
    test "rejects key with wrong length" do
      changeset = build_changeset(%{key: "abc"})
      assert %{key: ["should be 6 character(s)"]} = errors_on(changeset)
    end

    test "enforces unique constraint on key" do
      account = account_fixture()

      {:error, changeset} =
        %Account{}
        |> cast(valid_account_attrs(%{key: account.key}), [:name, :slug, :legal_name, :key])
        |> Account.changeset()
        |> Repo.insert()

      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
