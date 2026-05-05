defmodule Portal.Repo.Migrations.RenameRemoteIpColumnsOnPolicyAuthorizations do
  use Ecto.Migration

  def change do
    rename(table(:policy_authorizations), :client_remote_ip, to: :initiator_remote_ip)
    rename(table(:policy_authorizations), :gateway_remote_ip, to: :receiver_remote_ip)
    rename(table(:policy_authorizations), :client_user_agent, to: :initiator_user_agent)
  end
end
