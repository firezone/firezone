defmodule PortalWeb.Plugs.FetchAccount do
  @behaviour Plug

  import Plug.Conn
  alias __MODULE__.Database

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [account_id_or_slug | _rest]} = conn, _opts) do
    case Database.get_account_by_id_or_slug(account_id_or_slug) do
      nil -> conn
      %Portal.Account{} = account -> assign(conn, :account, account)
    end
  end

  def call(conn, _opts), do: conn

  defmodule Database do
    import Ecto.Query
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Portal.Repo.fetch_unscoped(:one)
    end
  end
end
