defmodule Portal.Accounts.Activity do
  @moduledoc """
  An account is active when it has at least one row in `session_logs`.

  Session logs are kept for 90 days, so an account with no client, gateway, or
  portal session in that window has nobody using it. Recurring notifications
  skip those accounts. Emails an admin triggers themselves, such as sign-in
  links and the account deletion sequence, are always delivered.
  """

  alias __MODULE__.Database

  @doc """
  Returns true when the account has a session in the session log retention window.
  """
  def account_active?(account_id) do
    Database.active_account_ids([account_id]) != []
  end

  @doc """
  Returns the ids in `account_ids` whose accounts are active.
  """
  def active_account_ids(account_ids) do
    account_ids
    |> Database.active_account_ids()
    |> MapSet.new()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.Safe
    alias Portal.SessionLog

    def active_account_ids([]), do: []

    def active_account_ids(account_ids) do
      from(a in Account, as: :accounts)
      |> where([accounts: a], a.id in ^account_ids)
      |> where(
        [accounts: a],
        exists(
          from(sl in SessionLog,
            where: sl.account_id == parent_as(:accounts).id,
            select: 1
          )
        )
      )
      |> select([accounts: a], a.id)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
