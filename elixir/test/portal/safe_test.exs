defmodule Portal.SafeTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.SubjectFixtures
  alias Portal.Safe
  alias Portal.Account

  defmodule FlakyRepo do
    @moduledoc false
    # Stands in for a pool that drops its connection during a transient
    # outage, raising the same error Postgrex surfaces in production.
    def one(_query),
      do: raise(DBConnection.ConnectionError, "ssl recv (idle): closed")
  end

  describe "connection errors" do
    setup do
      account = account_fixture()
      query = from(a in Account, where: a.id == ^account.id)
      %{account: account, query: query}
    end

    test "propagate to the caller", %{query: query} do
      assert_raise DBConnection.ConnectionError, fn ->
        query
        |> Safe.unscoped(FlakyRepo)
        |> Safe.one()
      end
    end
  end

  describe "delete/1" do
    test "returns not_found when the row was already deleted" do
      account = account_fixture()
      subject = admin_subject_fixture(account: account)
      site = Portal.SiteFixtures.site_fixture(account: account)

      assert {:ok, _site} = site |> Safe.scoped(subject) |> Safe.delete()
      assert {:error, :not_found} = site |> Safe.scoped(subject) |> Safe.delete()
    end
  end

  # Exhaustive specification of the authorization matrix encoded in
  # `Portal.Safe.permit/3`. Each assertion pins one clause so that an accidental
  # change to a permission rule fails a test rather than silently widening or
  # narrowing access. The actor-type heads are exercised directly, which is the
  # exact code path the `%Subject{}` head delegates to.

  @all_types [:account_admin_user, :api_client, :account_user, :service_account]

  describe "permit/3 grants" do
    test "Account: admin all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Account, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.Account, :api_client) == :ok
      assert Safe.permit(:read, Portal.Account, :account_user) == :ok
      assert Safe.permit(:read, Portal.Account, :service_account) == :ok
    end

    test "Actor: admin and api_client only" do
      assert Safe.permit(:delete, Portal.Actor, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Actor, :api_client) == :ok
    end

    test "Group: admin and api_client all actions, account_user may read" do
      assert Safe.permit(:delete, Portal.Group, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Group, :api_client) == :ok
      assert Safe.permit(:read, Portal.Group, :account_user) == :ok
    end

    test "ExternalIdentity: admin and api_client only" do
      assert Safe.permit(:delete, Portal.ExternalIdentity, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.ExternalIdentity, :api_client) == :ok
    end

    test "APIToken: admin only" do
      assert Safe.permit(:delete, Portal.APIToken, :account_admin_user) == :ok
    end

    test "Directory: admin all actions, api_client may read" do
      assert Safe.permit(:delete, Portal.Directory, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.Directory, :api_client) == :ok
    end

    test "AuthProvider (base): admin all actions, api_client may read" do
      assert Safe.permit(:delete, Portal.AuthProvider, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.AuthProvider, :api_client) == :ok
    end

    test "provider-specific AuthProviders: admin all actions, api_client may read" do
      for schema <- [
            Portal.Entra.AuthProvider,
            Portal.Google.AuthProvider,
            Portal.Okta.AuthProvider,
            Portal.OIDC.AuthProvider,
            Portal.EmailOTP.AuthProvider,
            Portal.Userpass.AuthProvider,
            Portal.X509.AuthProvider
          ] do
        assert Safe.permit(:delete, schema, :account_admin_user) == :ok
        assert Safe.permit(:read, schema, :api_client) == :ok
      end
    end

    test "provider-specific Directories: admin all actions, api_client may read" do
      for schema <- [Portal.Entra.Directory, Portal.Google.Directory, Portal.Okta.Directory] do
        assert Safe.permit(:delete, schema, :account_admin_user) == :ok
        assert Safe.permit(:read, schema, :api_client) == :ok
      end
    end

    test "PortalSession: admin only" do
      assert Safe.permit(:delete, Portal.PortalSession, :account_admin_user) == :ok
    end

    test "Oban.Job: admin may read" do
      assert Safe.permit(:read, Oban.Job, :account_admin_user) == :ok
    end

    test "Device: admin and api_client all actions, account_user/service_account read+insert" do
      assert Safe.permit(:delete, Portal.Device, :account_admin_user) == :ok
      assert Safe.permit(:update, Portal.Device, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Device, :api_client) == :ok
      assert Safe.permit(:update, Portal.Device, :api_client) == :ok

      for type <- [:account_user, :service_account] do
        assert Safe.permit(:read, Portal.Device, type) == :ok
        assert Safe.permit(:insert, Portal.Device, type) == :ok
        assert Safe.permit(:update, Portal.Device, type) == {:error, :unauthorized}
        assert Safe.permit(:delete, Portal.Device, type) == {:error, :unauthorized}
      end
    end

    test "PolicyAuthorization: any type may read and insert, only admin may delete" do
      for type <- @all_types do
        assert Safe.permit(:read, Portal.PolicyAuthorization, type) == :ok
        assert Safe.permit(:insert, Portal.PolicyAuthorization, type) == :ok
      end

      assert Safe.permit(:delete, Portal.PolicyAuthorization, :account_admin_user) == :ok
    end

    test "Site: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Site, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Site, :api_client) == :ok
      assert Safe.permit(:read, Portal.Site, :account_user) == :ok
      assert Safe.permit(:read, Portal.Site, :service_account) == :ok
    end

    test "DeviceToken: admin and api_client only" do
      assert Safe.permit(:delete, Portal.DeviceToken, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.DeviceToken, :api_client) == :ok
    end

    test "Resource: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Resource, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Resource, :api_client) == :ok
      assert Safe.permit(:read, Portal.Resource, :account_user) == :ok
    end

    test "Policy: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Policy, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Policy, :api_client) == :ok
      assert Safe.permit(:read, Portal.Policy, :account_user) == :ok
    end

    test "Membership: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Membership, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Membership, :api_client) == :ok
      assert Safe.permit(:read, Portal.Membership, :account_user) == :ok
    end

    test "ChangeLog: admin and api_client may read" do
      assert Safe.permit(:read, Portal.ChangeLog, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.ChangeLog, :api_client) == :ok
    end

    test "SessionLog: admin and api_client may read" do
      assert Safe.permit(:read, Portal.SessionLog, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.SessionLog, :api_client) == :ok
    end

    test "FlowLog: admin and api_client may read" do
      assert Safe.permit(:read, Portal.FlowLog, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.FlowLog, :api_client) == :ok
    end

    test "APIRequestLog: admin and api_client may read" do
      assert Safe.permit(:read, Portal.APIRequestLog, :account_admin_user) == :ok
      assert Safe.permit(:read, Portal.APIRequestLog, :api_client) == :ok
    end
  end

  describe "permit/3 denials" do
    test "lower-privilege types are denied admin-only schemas" do
      assert Safe.permit(:read, Portal.Actor, :account_user) == {:error, :unauthorized}
      assert Safe.permit(:read, Portal.ExternalIdentity, :service_account) == {:error, :unauthorized}
      assert Safe.permit(:read, Portal.APIToken, :api_client) == {:error, :unauthorized}
      assert Safe.permit(:read, Portal.DeviceToken, :account_user) == {:error, :unauthorized}
    end

    test "non-read actions are denied where only read is granted" do
      assert Safe.permit(:delete, Portal.Directory, :api_client) == {:error, :unauthorized}
      assert Safe.permit(:update, Portal.AuthProvider, :api_client) == {:error, :unauthorized}
      assert Safe.permit(:delete, Portal.ChangeLog, :account_admin_user) == {:error, :unauthorized}
      assert Safe.permit(:delete, Portal.Site, :account_user) == {:error, :unauthorized}
      assert Safe.permit(:delete, Portal.PolicyAuthorization, :account_user) == {:error, :unauthorized}
    end

    test "service_account may not read Group" do
      assert Safe.permit(:read, Portal.Group, :service_account) == {:error, :unauthorized}
    end

    test "unknown schema/type combinations fall through to unauthorized" do
      assert Safe.permit(:read, __MODULE__, :account_admin_user) == {:error, :unauthorized}
      assert Safe.permit(:delete, Portal.ChangeLog, :service_account) == {:error, :unauthorized}
    end
  end

  describe "scoped bulk writes" do
    setup do
      account = account_fixture()
      other_account = account_fixture()

      %{
        account: account,
        other_account: other_account,
        subject: admin_subject_fixture(account: account)
      }
    end

    test "insert_all stamps the subject's account on entries that omit it", %{
      account: account,
      subject: subject
    } do
      assert {1, nil} =
               Safe.scoped(subject)
               |> Safe.insert_all(Portal.Group, [group_entry("Stamped")])

      assert [group] = Repo.all(Portal.Group)
      assert group.account_id == account.id
      assert group.name == "Stamped"
    end

    test "insert_all refuses entries naming another account", %{
      other_account: other_account,
      subject: subject
    } do
      entries = [group_entry("Mine"), group_entry("Theirs", other_account.id)]

      assert {:error, :unauthorized} =
               Safe.scoped(subject) |> Safe.insert_all(Portal.Group, entries)

      assert Repo.all(Portal.Group) == []
    end

    test "insert_all refuses the query form", %{subject: subject} do
      query = from(g in Portal.Group, select: %{})

      assert {:error, :unauthorized} =
               Safe.scoped(subject) |> Safe.insert_all(Portal.Group, query)
    end

    test "update_all only touches rows in the subject's account", %{
      account: account,
      other_account: other_account,
      subject: subject
    } do
      Safe.unscoped()
      |> Safe.insert_all(Portal.Group, [
        group_entry("Mine", account.id),
        group_entry("Theirs", other_account.id)
      ])

      assert {1, nil} =
               from(g in Portal.Group)
               |> Safe.scoped(subject)
               |> Safe.update_all(set: [name: "Renamed"])

      assert Repo.get_by!(Portal.Group, account_id: account.id).name == "Renamed"
      assert Repo.get_by!(Portal.Group, account_id: other_account.id).name == "Theirs"
    end
  end

  defp group_entry(name, account_id \\ nil) do
    now = DateTime.utc_now()

    entry = %{
      id: Ecto.UUID.generate(),
      name: name,
      type: :static,
      entity_type: :group,
      inserted_at: now,
      updated_at: now
    }

    if account_id, do: Map.put(entry, :account_id, account_id), else: entry
  end

  describe "legacy_gateway actor" do
    setup do
      account = account_fixture()
      actor = Portal.ActorFixtures.legacy_gateway_actor_fixture(account: account)
      %{account: account, actor: actor, subject: admin_subject_fixture(account: account)}
    end

    test "is hidden from scoped reads", %{actor: actor, subject: subject} do
      assert from(a in Portal.Actor, where: a.id == ^actor.id) |> Safe.scoped(subject) |> Safe.one() == nil
      refute actor.id in (from(a in Portal.Actor) |> Safe.scoped(subject) |> Safe.all() |> Enum.map(& &1.id))
      assert from(a in Portal.Actor, where: a.id == ^actor.id) |> Safe.scoped(subject) |> Safe.aggregate(:count) == 0
    end

    test "stays visible to unscoped reads", %{actor: actor} do
      assert %Portal.Actor{} = from(a in Portal.Actor, where: a.id == ^actor.id) |> Safe.unscoped() |> Safe.one()
    end

    test "cannot be deleted or bulk-changed by an admin", %{actor: actor, subject: subject} do
      assert {:error, :unauthorized} = actor |> Safe.scoped(subject) |> Safe.delete()

      assert {:error, :unauthorized} =
               actor |> Ecto.Changeset.change() |> Safe.scoped(subject) |> Safe.delete()

      assert {0, _} = from(a in Portal.Actor, where: a.id == ^actor.id) |> Safe.scoped(subject) |> Safe.delete_all()

      assert {0, _} =
               from(a in Portal.Actor, where: a.id == ^actor.id)
               |> Safe.scoped(subject)
               |> Safe.update_all(set: [name: "Renamed"])

      assert %Portal.Actor{name: "Legacy Gateway"} = Repo.get_by(Portal.Actor, id: actor.id)
    end

    test "as a subject type it may only read Sites and register and update Gateways" do
      for {action, schema} <- [
            {:read, Portal.Site},
            {:read, Portal.Device},
            {:insert, Portal.Device},
            {:update, Portal.Device}
          ] do
        assert Safe.permit(action, schema, :legacy_gateway) == :ok
      end

      for {action, schema} <- [
            {:update, Portal.Site},
            {:delete, Portal.Device},
            {:read, Portal.SiteDevice},
            {:read, Portal.DeviceToken},
            {:insert, Portal.DeviceToken},
            {:read, Portal.Resource},
            {:read, Portal.Policy},
            {:read, Portal.Membership},
            {:read, Portal.PolicyAuthorization},
            {:insert, Portal.PolicyAuthorization},
            {:read, Portal.Account},
            {:read, Portal.Actor}
          ] do
        assert Safe.permit(action, schema, :legacy_gateway) == {:error, :unauthorized}
      end
    end
  end
end
