defmodule Domain.Accounts.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Accounts.Account

  def manage_own_account_permission, do: build(Account, :manage_own)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(:account_admin_user) do
    [
      manage_own_account_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_own_account_permission()) ->
        Account.Query.by_id(queryable, subject.account.id)
    end
  end
end
