# REMOVEME? Better explicit code in controllers
defmodule Web.Plugs.FetchAccount do
  alias Domain.Accounts

  @behaviour Plug

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"account_id" => account_id}} = conn, _opts) do
    with {:ok, account} <- Accounts.fetch_account_by_id(account_id) do
      Plug.Conn.assign(conn, :account, account)
    else
      {:error, _reason} ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> Phoenix.Controller.put_view(html: Web.ErrorHTML)
        |> Phoenix.Controller.render("404.html")
        |> Plug.Conn.halt()
    end
  end
end
