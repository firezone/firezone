# Email Testing Script for IEx
#
# Usage:
#   iex -S mix
#   iex> c "scripts/test_emails.exs"
#   iex> TestEmails.send_all_test_emails()
#
# Then visit: http://localhost:13000/dev/mailbox
#
# To test dark mode:
# 1. Open an email in the mailbox
# 2. Open browser dev tools (F12)
# 3. Toggle dark mode: System Preferences → Appearance → Dark
#    Or use dev tools to emulate dark mode

defmodule TestEmails do
  @moduledoc """
  Helper module for generating test emails in development.
  All emails will appear in the Swoosh mailbox at http://localhost:13000/dev/mailbox
  """

  alias Domain.{Accounts, Auth, Actors, Repo, Mailer}

  def send_all_test_emails do
    IO.puts("\n🚀 Generating test emails...")
    IO.puts("View them at: http://localhost:13000/dev/mailbox\n")

    with {:ok, _} <- send_sign_up_link_email(),
         {:ok, _} <- send_sign_in_link_email(),
         {:ok, _} <- send_new_user_email(),
         {:ok, _} <- send_outdated_gateway_email(),
         {:ok, _} <- send_sync_error_email() do
      IO.puts("\n✅ All test emails sent successfully!")
      IO.puts("📬 Open http://localhost:13000/dev/mailbox to view them\n")
      :ok
    else
      {:error, reason} ->
        IO.puts("\n❌ Error sending emails: #{inspect(reason)}\n")
        {:error, reason}
    end
  end

  def send_sign_up_link_email do
    IO.puts("📧 Generating sign-up welcome email...")

    account = get_or_create_test_account()
    provider = get_or_create_email_provider(account)
    actor = get_or_create_test_actor(account, :account_admin_user)
    identity = get_or_create_identity(account, provider, actor)

    email =
      Mailer.AuthEmail.sign_up_link_email(
        account,
        identity,
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        {127, 0, 0, 1}
      )

    Mailer.deliver(email)
  end

  def send_sign_in_link_email do
    IO.puts("📧 Generating sign-in token email...")

    account = get_or_create_test_account()
    provider = get_or_create_email_provider(account)
    actor = get_or_create_test_actor(account, :account_user)
    identity = get_or_create_identity(account, provider, actor)

    # Set up the identity with token state
    identity =
      identity
      |> Ecto.Changeset.change(
        provider_state: %{
          "token_created_at" => DateTime.utc_now()
        }
      )
      |> Repo.update!()
      |> Repo.preload(:account)

    secret = "ABC123XYZ789"

    email =
      Mailer.AuthEmail.sign_in_link_email(
        identity,
        secret,
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        {127, 0, 0, 1}
      )

    Mailer.deliver(email)
  end

  def send_new_user_email do
    IO.puts("📧 Generating new user invitation email...")

    account = get_or_create_test_account()
    provider = get_or_create_email_provider(account)
    admin_actor = get_or_create_test_actor(account, :account_admin_user, "Admin User")
    admin_identity = get_or_create_identity(account, provider, admin_actor, "admin@test.local")
    new_actor = get_or_create_test_actor(account, :account_user, "New User", "new_user")
    new_identity = get_or_create_identity(account, provider, new_actor, "newuser@test.local")

    subject = %Auth.Subject{
      account: account,
      actor: admin_actor,
      identity: admin_identity,
      permissions: MapSet.new(),
      token_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      context: %Auth.Context{
        type: :browser,
        remote_ip: {127, 0, 0, 1},
        user_agent: "Mozilla/5.0 (Test)"
      }
    }

    email = Mailer.AuthEmail.new_user_email(account, new_identity, subject)

    Mailer.deliver(email)
  end

  def send_outdated_gateway_email do
    IO.puts("📧 Generating outdated gateway notification email...")

    # Create a test gateway
    account = get_or_create_test_account()

    # Create a gateway group
    group = get_or_create_gateway_group(account)

    gateway1 =
      Repo.insert!(
        %Domain.Gateways.Gateway{
          account_id: account.id,
          group_id: group.id,
          external_id: "test-gateway-us-east",
          name: "Gateway US East",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          last_seen_user_agent: "Linux/1.0.0",
          last_seen_remote_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
          last_seen_version: "1.0.0",
          last_seen_at: DateTime.utc_now()
        },
        on_conflict: :nothing
      )

    gateway2 =
      Repo.insert!(
        %Domain.Gateways.Gateway{
          account_id: account.id,
          group_id: group.id,
          external_id: "test-gateway-eu-west",
          name: "Gateway EU West",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          last_seen_user_agent: "Linux/1.0.1",
          last_seen_remote_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
          last_seen_version: "1.0.1",
          last_seen_at: DateTime.utc_now()
        },
        on_conflict: :nothing
      )

    admin_actor = get_or_create_test_actor(account, :account_admin_user)
    provider = get_or_create_email_provider(account)
    admin_identity = get_or_create_identity(account, provider, admin_actor)

    # Set incompatible_client_count to 3 to trigger the optional warning section
    email =
      Mailer.Notifications.outdated_gateway_email(
        account,
        [gateway1, gateway2],
        3,
        admin_identity.provider_identifier
      )

    Mailer.deliver(email)
  end

  def send_sync_error_email do
    IO.puts("📧 Generating sync error email...")

    account = get_or_create_test_account()

    # Create or get a test OIDC provider with sync error
    provider =
      case Repo.get_by(Auth.Provider, account_id: account.id, name: "Okta Directory Sync Test") do
        nil ->
          Repo.insert!(%Auth.Provider{
            account_id: account.id,
            name: "Okta Directory Sync Test",
            adapter: :openid_connect,
            adapter_state: %{},
            adapter_config: %{
              "discovery_document_uri" =>
                "https://dev-123456.okta.com/.well-known/openid-configuration",
              "client_id" => "test_client_id",
              "client_secret" => "test_client_secret",
              "response_type" => "code",
              "scope" => "openid email profile"
            },
            created_by: :system,
            created_by_subject: %{"name" => "System", "email" => nil},
            provisioner: :manual,
            last_sync_error:
              "Connection timeout: Unable to reach identity provider API at https://dev-123456.okta.com",
            last_syncs_failed: 3
          })

        provider ->
          provider
      end

    admin_actor = get_or_create_test_actor(account, :account_admin_user)
    email_provider = get_or_create_email_provider(account)
    admin_identity = get_or_create_identity(account, email_provider, admin_actor)

    # Preload the account association
    provider = Repo.preload(provider, :account)

    email =
      Mailer.SyncEmail.sync_error_email(
        provider,
        admin_identity.provider_identifier
      )

    Mailer.deliver(email)
  end

  # Helper functions

  defp get_or_create_test_account do
    case Repo.get_by(Accounts.Account, slug: "test_email_account") do
      nil ->
        {:ok, account} =
          Accounts.create_account(%{
            name: "Test Email Account",
            slug: "test_email_account"
          })

        account

      account ->
        account
    end
  end

  defp get_or_create_email_provider(account) do
    case Repo.get_by(Auth.Provider, account_id: account.id, adapter: :email) do
      nil ->
        {:ok, provider} =
          Auth.create_provider(account, %{
            name: "Email",
            adapter: :email,
            adapter_config: %{},
            created_by: :system,
            provisioner: :manual
          })

        provider

      provider ->
        provider
    end
  end

  defp get_or_create_test_actor(account, type, name \\ "Test User", slug_suffix \\ "test") do
    slug = "test-actor-#{slug_suffix}"

    case Repo.get_by(Actors.Actor, account_id: account.id, name: slug) do
      nil ->
        Repo.insert!(%Actors.Actor{
          account_id: account.id,
          type: type,
          name: name
        })

      actor ->
        actor
    end
  end

  defp get_or_create_identity(account, provider, actor, email \\ "test@test.local") do
    case Repo.get_by(Auth.Identity,
           account_id: account.id,
           provider_id: provider.id,
           actor_id: actor.id
         ) do
      nil ->
        {:ok, identity} =
          Auth.upsert_identity(actor, provider, %{
            provider_identifier: email,
            provider_identifier_confirmation: email,
            provider_virtual_state: %{}
          })

        identity

      identity ->
        identity
    end
  end

  defp get_or_create_gateway_group(account) do
    case Repo.get_by(Domain.Gateways.Group, account_id: account.id, name: "Test Gateway Group") do
      nil ->
        Repo.insert!(%Domain.Gateways.Group{
          account_id: account.id,
          name: "Test Gateway Group",
          managed_by: :account,
          created_by: :system
        })

      group ->
        group
    end
  end
end

# Print usage instructions
IO.puts("""

╔══════════════════════════════════════════════════════════════╗
║             Email Testing Script Loaded                     ║
╚══════════════════════════════════════════════════════════════╝

Usage:
  TestEmails.send_all_test_emails()

Individual emails:
  TestEmails.send_sign_up_link_email()
  TestEmails.send_sign_in_link_email()
  TestEmails.send_new_user_email()
  TestEmails.send_outdated_gateway_email()
  TestEmails.send_sync_error_email()

View emails at: http://localhost:13000/dev/mailbox

To test dark mode:
1. Open an email in the mailbox
2. Toggle macOS system appearance: System Settings → Appearance → Dark
3. Or use browser dev tools to emulate prefers-color-scheme: dark

""")
