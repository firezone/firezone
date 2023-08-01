defmodule Domain.Accounts.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Accounts.Account

  def view_accounts_permission, do: build(Account, :view)

  @impl Domain.Auth.Authorizer
  def list_permissions_for_role(_) do
    [view_accounts_permission()]
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, view_accounts_permission()) ->
        Account.Query.by_id(queryable, subject.account.id)
    end
  end
end
