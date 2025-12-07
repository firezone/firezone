defmodule Web.Plugs.PutSTSHeader do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    scheme =
      conn.private.phoenix_endpoint.config(:url, [])
      |> Keyword.get(:scheme)

    if scheme == "https" do
      Plug.Conn.put_resp_header(
        conn,
        "strict-transport-security",
        "max-age=63072000; includeSubDomains; preload"
      )
    else
      conn
    end
  end
end
