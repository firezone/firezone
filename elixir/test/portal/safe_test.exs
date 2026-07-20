defmodule Portal.SafeTest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.Safe
  alias Portal.Account

  defmodule FlakyReplica do
    @moduledoc false
    # Stands in for a read replica that drops its connection during a transient
    # outage, raising the same error Postgrex surfaces in production.
    def one(_query),
      do: raise(DBConnection.ConnectionError, "ssl recv (idle): closed")

    def exists?(_query),
      do: raise(DBConnection.ConnectionError, "ssl recv (idle): closed")
  end

  describe "fallback_to_primary on replica connection errors" do
    setup do
      account = account_fixture()
      query = from(a in Account, where: a.id == ^account.id)
      %{account: account, query: query}
    end

    test "one/2 falls back to the primary", %{account: account, query: query} do
      assert result =
               query
               |> Safe.unscoped(FlakyReplica)
               |> Safe.one(fallback_to_primary: true)

      assert result.id == account.id
    end

    test "one!/2 falls back to the primary", %{account: account, query: query} do
      assert result =
               query
               |> Safe.unscoped(FlakyReplica)
               |> Safe.one!(fallback_to_primary: true)

      assert result.id == account.id
    end

    test "exists?/2 falls back to the primary", %{query: query} do
      assert query
             |> Safe.unscoped(FlakyReplica)
             |> Safe.exists?(fallback_to_primary: true)
    end

    test "re-raises when fallback is disabled", %{query: query} do
      assert_raise DBConnection.ConnectionError, fn ->
        query
        |> Safe.unscoped(FlakyReplica)
        |> Safe.one()
      end
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

    test "ClientToken: admin and api_client only" do
      assert Safe.permit(:delete, Portal.ClientToken, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.ClientToken, :api_client) == :ok
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
            Portal.Userpass.AuthProvider
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

    test "Device: admin and api_client all actions, account_user/service_account read+update" do
      assert Safe.permit(:delete, Portal.Device, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Device, :api_client) == :ok
      assert Safe.permit(:read, Portal.Device, :account_user) == :ok
      assert Safe.permit(:update, Portal.Device, :account_user) == :ok
      assert Safe.permit(:read, Portal.Device, :service_account) == :ok
      assert Safe.permit(:update, Portal.Device, :service_account) == :ok
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

    test "GatewayToken: admin and api_client only" do
      assert Safe.permit(:delete, Portal.GatewayToken, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.GatewayToken, :api_client) == :ok
    end

    test "Resource: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.Resource, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.Resource, :api_client) == :ok
      assert Safe.permit(:read, Portal.Resource, :account_user) == :ok
    end

    test "StaticDevicePoolMember: admin and api_client all actions, every type may read" do
      assert Safe.permit(:delete, Portal.StaticDevicePoolMember, :account_admin_user) == :ok
      assert Safe.permit(:delete, Portal.StaticDevicePoolMember, :api_client) == :ok
      assert Safe.permit(:read, Portal.StaticDevicePoolMember, :account_user) == :ok
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
      assert Safe.permit(:read, Portal.ClientToken, :account_user) == {:error, :unauthorized}
      assert Safe.permit(:read, Portal.APIToken, :api_client) == {:error, :unauthorized}
      assert Safe.permit(:read, Portal.GatewayToken, :account_user) == {:error, :unauthorized}
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
end
