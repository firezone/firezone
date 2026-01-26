# TODO: IDP REFACTOR
# Fix up this task once sync error emails are back in place
# defmodule Mix.Tasks.Email.Render do
#   @moduledoc """
#   Render email templates for development and testing purposes.
#
#   All emails will appear in the Swoosh mailbox at https://localhost:13443/dev/mailbox
#
#   ## Usage
#
#       # Make sure no iex session is running, then:
#       $ mix email.render
#
#       # Then visit: https://localhost:13443/dev/mailbox
#
#       # The task will:
#       # 1. Start the application
#       # 2. Generate test emails
#       # 3. Keep running so you can view the emails
#       # 4. Press Ctrl+C twice to exit when done
#
#   ## Examples
#
#       # Send all test emails
#       $ mix email.render
#
#       # Send specific emails
#       $ mix email.render sign_up
#       $ mix email.render sign_in
#       $ mix email.render new_user
#       $ mix email.render outdated_gateway
#       $ mix email.render sync_error
#
#   ## Testing Dark Mode
#
#   1. Open an email in the mailbox at http://localhost:13443/dev/mailbox
#   2. Toggle macOS system appearance: System Settings → Appearance → Dark
#   3. Or use browser dev tools to emulate prefers-color-scheme: dark
#
#   ## Note
#
#   The application stays running after sending emails so you can view them in the
#   mailbox. Emails are stored in memory and will be lost when the app exits.
#   """
#
#   @shortdoc "Render email templates for development"
#
#   use Mix.Task
#
#   alias Portal.{Accounts, Auth, Actors, Repo, Mailer, Okta}
#
#   @impl true
#   def run(args) do
#     # Start the application (including Repo, Swoosh, and all services)
#     Mix.Task.run("app.start")
#
#     case args do
#       [] ->
#         send_all_test_emails()
#         keep_running()
#
#       ["sign_up"] ->
#         send_sign_up_link_email()
#         keep_running()
#
#       ["sign_in"] ->
#         send_sign_in_link_email()
#         keep_running()
#
#       ["new_user"] ->
#         send_new_user_email()
#         keep_running()
#
#       ["outdated_gateway"] ->
#         send_outdated_gateway_email()
#         keep_running()
#
#       ["sync_error"] ->
#         send_sync_error_email()
#         keep_running()
#
#       _ ->
#         Mix.shell().error("""
#         Unknown argument: #{Enum.join(args, " ")}
#
#         Valid options:
#           mix email.render                 # Send all test emails
#           mix email.render sign_up
#           mix email.render sign_in
#           mix email.render new_user
#           mix email.render outdated_gateway
#           mix email.render sync_error
#         """)
#
#         exit({:shutdown, 1})
#     end
#   end
#
#   defp send_all_test_emails do
#     Mix.shell().info("\n🚀 Generating test emails...")
#
#     with {:ok, _} <- send_sign_up_link_email(),
#          {:ok, _} <- send_sign_in_link_email(),
#          {:ok, _} <- send_new_user_email(),
#          {:ok, _} <- send_outdated_gateway_email(),
#          {:ok, _} <- send_sync_error_email() do
#       Mix.shell().info("\n✅ All test emails sent successfully!")
#       :ok
#     else
#       {:error, reason} ->
#         Mix.shell().error("\n❌ Error sending emails: #{inspect(reason)}\n")
#         exit({:shutdown, 1})
#     end
#   end
#
#   defp keep_running do
#     Mix.shell().info("\n📬 Open https://localhost:13443/dev/mailbox to view the emails")
#     Mix.shell().info("\n⏳ Keeping app running so you can view the emails...")
#     Mix.shell().info("   Press Ctrl+C twice to exit when done.\n")
#
#     # Keep the app running so emails stay in memory
#     :timer.sleep(:infinity)
#   end
#
#   defp send_sign_up_link_email do
#     Mix.shell().info("📧 Generating sign-up welcome email...")
#
#     account = get_or_create_test_account()
#     provider = get_or_create_email_provider(account)
#     actor = get_or_create_test_actor(account, :account_admin_user)
#     identity = get_or_create_identity(account, provider, actor)
#
#     email =
#       Mailer.AuthEmail.sign_up_link_email(
#         account,
#         identity,
#         "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
#         {127, 0, 0, 1}
#       )
#
#     Mailer.deliver(email)
#   end
#
#   defp send_sign_in_link_email do
#     Mix.shell().info("📧 Generating sign-in token email...")
#
#     account = get_or_create_test_account()
#     provider = get_or_create_email_provider(account)
#     actor = get_or_create_test_actor(account, :account_user)
#     identity = get_or_create_identity(account, provider, actor)
#
#     # Set up the identity with token state
#     identity =
#       identity
#       |> Ecto.Changeset.change(
#         provider_state: %{
#           "token_created_at" => DateTime.utc_now()
#         }
#       )
#       |> Repo.update!()
#       |> Repo.preload(:account)
#
#     secret = "ABC123XYZ789"
#
#     email =
#       Mailer.AuthEmail.sign_in_link_email(
#         identity,
#         secret,
#         "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
#         {127, 0, 0, 1}
#       )
#
#     Mailer.deliver(email)
#   end
#
#   defp send_new_user_email do
#     Mix.shell().info("📧 Generating new user invitation email...")
#
#     account = get_or_create_test_account()
#     provider = get_or_create_email_provider(account)
#     admin_actor = get_or_create_test_actor(account, :account_admin_user, "Admin User")
#     admin_identity = get_or_create_identity(account, provider, admin_actor, "admin@test.local")
#     new_actor = get_or_create_test_actor(account, :account_user, "New User", "new_user")
#     new_identity = get_or_create_identity(account, provider, new_actor, "newuser@test.local")
#
#     subject = %Authentication.Subject{
#       account: account,
#       actor: admin_actor,
#       identity: admin_identity,
#       permissions: MapSet.new(),
#       token_id: Ecto.UUID.generate(),
#       expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
#       context: %Authentication.Context{
#         type: :browser,
#         remote_ip: {127, 0, 0, 1},
#         user_agent: "Mozilla/5.0 (Test)"
#       }
#     }
#
#     email = Mailer.AuthEmail.new_user_email(account, new_identity, subject)
#
#     Mailer.deliver(email)
#   end
#
#   defp send_outdated_gateway_email do
#     Mix.shell().info("📧 Generating outdated gateway notification email...")
#
#     # Create a test gateway
#     account = get_or_create_test_account()
#
#     # Create a site
#     site = get_or_create_site(account)
#
#     gateway1 =
#       Repo.insert!(
#         %Portal.Gateway{
#           account_id: account.id,
#           site_id: site.id,
#           external_id: "test-gateway-us-east",
#           name: "Gateway US East",
#           public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
#           last_seen_user_agent: "Linux/1.0.0",
#           last_seen_remote_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
#           last_seen_version: "1.0.0",
#           last_seen_at: DateTime.utc_now()
#         },
#         on_conflict: :nothing
#       )
#
#     gateway2 =
#       Repo.insert!(
#         %Portal.Gateway{
#           account_id: account.id,
#           group_id: group.id,
#           external_id: "test-gateway-eu-west",
#           name: "Gateway EU West",
#           public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
#           last_seen_user_agent: "Linux/1.0.1",
#           last_seen_remote_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
#           last_seen_version: "1.0.1",
#           last_seen_at: DateTime.utc_now()
#         },
#         on_conflict: :nothing
#       )
#
#     admin_actor = get_or_create_test_actor(account, :account_admin_user)
#     provider = get_or_create_email_provider(account)
#     admin_identity = get_or_create_identity(account, provider, admin_actor)
#
#     # Set incompatible_client_count to 3 to trigger the optional warning section
#     email =
#       Mailer.Notifications.outdated_gateway_email(
#         account,
#         [gateway1, gateway2],
#         3,
#         admin_identity.provider_identifier
#       )
#
#     Mailer.deliver(email)
#   end
#
#   defp send_sync_error_email do
#     Mix.shell().info("📧 Generating sync error email...")
#
#     account = get_or_create_test_account()
#
#     # Create or get a test okta directory
#     provider =
#       case Repo.get_by(Okta.Directory, account_id: account.id, name: "Okta Directory Sync Test") do
#         nil ->
#           Repo.insert!(%Okta.Directory{
#             account_id: account.id,
#             name: "Okta Directory Sync Test",
#             adapter: :openid_connect,
#             adapter_state: %{},
#             adapter_config: %{
#               "discovery_document_uri" =>
#                 "https://dev-123456.okta.com/.well-known/openid-configuration",
#               "client_id" => "test_client_id",
#               "client_secret" => "test_client_secret",
#               "response_type" => "code",
#               "scope" => "openid email profile"
#             },
#             provisioner: :manual,
#             last_sync_error:
#               "Connection timeout: Unable to reach identity provider API at https://dev-123456.okta.com",
#             last_syncs_failed: 3
#           })
#
#         provider ->
#           provider
#       end
#
#     admin_actor = get_or_create_test_actor(account, :account_admin_user)
#     email_provider = get_or_create_email_provider(account)
#     admin_identity = get_or_create_identity(account, email_provider, admin_actor)
#
#     # Preload the account association
#     provider = Repo.preload(provider, :account)
#
#     email =
#       Mailer.SyncEmail.sync_error_email(
#         provider,
#         admin_identity.provider_identifier
#       )
#
#     Mailer.deliver(email)
#   end
#
#   # Helper functions
#
#   defp get_or_create_test_account do
#     case Repo.get_by(Portal.Account, slug: "test_email_account") do
#       nil ->
#         {:ok, account} =
#           Accounts.create_account(%{
#             name: "Test Email Account",
#             slug: "test_email_account"
#           })
#
#         account
#
#       account ->
#         account
#     end
#   end
#
#   defp get_or_create_email_provider(account) do
#     case Repo.get_by(Auth.Provider, account_id: account.id, adapter: :email) do
#       nil ->
#         {:ok, provider} =
#           Auth.create_provider(account, %{
#             name: "Email",
#             adapter: :email,
#             adapter_config: %{},
#             provisioner: :manual
#           })
#
#         provider
#
#       provider ->
#         provider
#     end
#   end
#
#   defp get_or_create_test_actor(account, type, name \\ "Test User", slug_suffix \\ "test") do
#     slug = "test-actor-#{slug_suffix}"
#
#     case Repo.get_by(Actor, account_id: account.id, name: slug) do
#       nil ->
#         Repo.insert!(%Portal.Actor{
#           account_id: account.id,
#           type: type,
#           name: name
#         })
#
#       actor ->
#         actor
#     end
#   end
#
#   defp get_or_create_identity(account, provider, actor, email \\ "test@test.local") do
#     case Repo.get_by(ExternalIdentity,
#            account_id: account.id,
#            provider_id: provider.id,
#            actor_id: actor.id
#          ) do
#       nil ->
#         {:ok, identity} =
#           Auth.upsert_identity(actor, provider, %{
#             provider_identifier: email,
#             provider_identifier_confirmation: email,
#             provider_virtual_state: %{}
#           })
#
#         identity
#
#       identity ->
#         identity
#     end
#   end
#
#   defp get_or_create_site(account) do
#     case Repo.get_by(Portal.Site, account_id: account.id, name: "Test Site") do
#       nil ->
#         Repo.insert!(%Portal.Site{
#           account_id: account.id,
#           name: "Test Site",
#           managed_by: :account,
#         })
#
#       group ->
#         group
#     end
#   end
# end
