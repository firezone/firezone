defmodule Web.Plugs.FetchAccount do
  @behaviour Plug

  import Plug.Conn
  alias __MODULE__.DB

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [account_id_or_slug | _rest]} = conn, _opts) do
    case DB.get_account_by_id_or_slug(account_id_or_slug) do
      nil -> conn
      %Domain.Account{} = account -> assign(conn, :account, account)
    end
  end

  def call(conn, _opts), do: conn

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Domain.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end
  end
end
