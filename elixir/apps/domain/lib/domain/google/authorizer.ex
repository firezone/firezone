defmodule Domain.Google.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Google.OIDCProvider

  def manage_oidc_providers_permission, do: build(OIDCProvider, :manage)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_oidc_providers_permission()
    ]
  end

  def list_permissions_for_role(:api_client) do
    [
      manage_oidc_providers_permission()
    ]
  end

  def list_permissions_for_role(_), do: []

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    if has_permission?(subject, manage_oidc_providers_permission()) do
      OIDCProvider.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
