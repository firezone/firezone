defmodule Web.Plugs.FetchAccount do
  @behaviour Plug

  import Plug.Conn
  alias Domain.Accounts

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [account_id_or_slug | _rest]} = conn, _opts) do
    case Accounts.fetch_account_by_id_or_slug(account_id_or_slug) do
      {:ok, account} -> assign(conn, :account, account)
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn
end
