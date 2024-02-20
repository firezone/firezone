defmodule Domain.Billing.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Billing

  def manage_own_account_billing_permission, do: build(Billing, :manage_own)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_own_account_billing_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end
end
