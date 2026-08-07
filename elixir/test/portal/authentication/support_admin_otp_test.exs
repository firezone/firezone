defmodule Portal.Authentication.SupportAdminOTPTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.SupportAdminFixtures

  alias Portal.Authentication
  alias Portal.SupportAdmin

  describe "create_support_admin_otp/1" do
    test "creates an OTP for a registered support admin" do
      {support_admin, _authenticator} = registered_support_admin_fixture()

      assert {:ok, updated} = Authentication.create_support_admin_otp(support_admin.email)
      assert is_binary(updated.otp_code)
      assert String.length(updated.otp_code) == 6
      assert updated.otp_attempts == 0
      assert DateTime.after?(updated.otp_expires_at, DateTime.utc_now())
      assert Portal.Crypto.equal?(:argon2, updated.otp_code, updated.otp_code_hash)
    end

    test "returns an error for an unknown email" do
      assert {:error, :not_found} =
               Authentication.create_support_admin_otp("unknown@firezone.dev")
    end

    test "returns an error when no passkey is registered" do
      support_admin = support_admin_fixture()

      assert {:error, :not_found} = Authentication.create_support_admin_otp(support_admin.email)
    end
  end

  describe "verify_support_admin_otp/2" do
    setup do
      {support_admin, _authenticator} = registered_support_admin_fixture()
      {:ok, support_admin} = Authentication.create_support_admin_otp(support_admin.email)
      %{support_admin: support_admin}
    end

    test "verifies a valid code and clears OTP state", %{support_admin: support_admin} do
      assert {:ok, verified} =
               Authentication.verify_support_admin_otp(
                 support_admin.email,
                 support_admin.otp_code
               )

      assert verified.email == support_admin.email

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert is_nil(reloaded.otp_code_hash)
      assert is_nil(reloaded.otp_expires_at)
      assert reloaded.otp_attempts == 0
    end

    test "rejects a wrong code and counts the attempt", %{support_admin: support_admin} do
      assert {:error, :invalid_code} =
               Authentication.verify_support_admin_otp(support_admin.email, "wrong1")

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert reloaded.otp_attempts == 1
    end

    test "clears the OTP after three failed attempts", %{support_admin: support_admin} do
      for _attempt <- 1..3 do
        assert {:error, :invalid_code} =
                 Authentication.verify_support_admin_otp(support_admin.email, "wrong1")
      end

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert is_nil(reloaded.otp_code_hash)

      assert {:error, :invalid_code} =
               Authentication.verify_support_admin_otp(
                 support_admin.email,
                 support_admin.otp_code
               )
    end

    test "rejects an expired code", %{support_admin: support_admin} do
      Portal.Repo.get!(SupportAdmin, support_admin.id)
      |> Ecto.Changeset.change(otp_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Portal.Repo.update!()

      assert {:error, :invalid_code} =
               Authentication.verify_support_admin_otp(
                 support_admin.email,
                 support_admin.otp_code
               )
    end

    test "rejects an unknown email" do
      assert {:error, :invalid_code} =
               Authentication.verify_support_admin_otp("unknown@firezone.dev", "abc123")
    end
  end

  describe "fetch_portal_session/2 with a support provider" do
    setup do
      account = account_fixture()
      provider = firezone_support_provider_fixture(account: account)
      actor = support_actor_fixture(account: account)

      context = %Authentication.Context{
        type: :portal,
        user_agent: "Test 1.0",
        remote_ip: {127, 0, 0, 1}
      }

      {:ok, session} =
        Authentication.create_portal_session(
          actor,
          provider.id,
          context,
          DateTime.add(DateTime.utc_now(), 3_600, :second)
        )

      %{account: account, provider: provider, session: session}
    end

    test "fetches a session while the provider is active", %{
      account: account,
      session: session
    } do
      assert {:ok, _session} = Authentication.fetch_portal_session(account.id, session.id)
    end

    test "rejects the session once the provider window has lapsed", %{
      account: account,
      provider: provider,
      session: session
    } do
      Portal.Repo.get_by!(Portal.FirezoneSupport.AuthProvider, id: provider.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Portal.Repo.update!()

      assert {:error, :not_found} = Authentication.fetch_portal_session(account.id, session.id)
    end
  end
end
