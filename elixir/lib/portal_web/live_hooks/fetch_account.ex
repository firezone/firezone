defmodule PortalWeb.LiveHooks.FetchAccount do
  alias __MODULE__.DB

  def on_mount(:default, %{"account_id_or_slug" => account_id_or_slug}, _session, socket)
      when is_binary(account_id_or_slug) do
    case DB.get_account_by_id_or_slug(account_id_or_slug) do
      nil -> {:cont, socket}
      %Portal.Account{} = account -> {:cont, Phoenix.Component.assign(socket, :account, account)}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do: from(a in Account, where: a.id == ^id_or_slug or a.slug == ^id_or_slug),
          else: from(a in Account, where: a.slug == ^id_or_slug)

      query |> Safe.unscoped() |> Safe.one()
    end
  end
end
