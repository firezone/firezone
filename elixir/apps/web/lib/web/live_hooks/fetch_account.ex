defmodule Web.LiveHooks.FetchAccount do
  alias Domain.Accounts

  def on_mount(:default, %{"account_id_or_slug" => account_id_or_slug}, _session, socket)
      when is_binary(account_id_or_slug) do
    case Accounts.fetch_account_by_id_or_slug(account_id_or_slug) do
      {:ok, account} -> {:cont, Phoenix.Component.assign(socket, :account, account)}
      _ -> {:cont, socket}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end
end
