defmodule PortalWeb.Plugs.PruneRecentAccounts do
  @moduledoc """
  Drops accounts that no longer exist from the recent accounts cookie.

  The sign-in chooser is a LiveView, which can't write cookies, so this runs on its route
  first. The ids that still exist, most recent first, are left in `conn.private` for the
  LiveView's session.
  """
  @behaviour Plug

  alias __MODULE__.Database
  alias PortalWeb.Cookie.RecentAccounts

  @private_key :recent_account_ids

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    %RecentAccounts{account_ids: account_ids} = RecentAccounts.fetch(conn)
    existing_ids = if account_ids == [], do: [], else: Database.existing_account_ids(account_ids)
    {kept, stale} = Enum.split_with(account_ids, &(&1 in existing_ids))

    conn = if stale == [], do: conn, else: RecentAccounts.remove(conn, stale)
    Plug.Conn.put_private(conn, @private_key, kept)
  end

  @doc "The recent account ids that still exist, most recent first."
  @spec account_ids(Plug.Conn.t()) :: [Ecto.UUID.t()]
  def account_ids(conn), do: conn.private[@private_key] || []

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    @spec existing_account_ids([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
    def existing_account_ids(account_ids) do
      from(a in Portal.Account, where: a.id in ^account_ids)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(& &1.id)
    end
  end
end
