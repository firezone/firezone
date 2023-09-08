defmodule Web.Plugs.SecureHeaders do
  @behaviour Plug

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    conn
    |> put_csp_nonce_and_header()
    |> maybe_put_sts_header()
  end

  defp put_csp_nonce_and_header(conn) do
    csp_nonce = Domain.Crypto.random_token(8)

    policy =
      Application.fetch_env!(:web, __MODULE__)
      |> Keyword.fetch!(:csp_policy)
      |> Enum.map(fn line ->
        String.replace(line, "${nonce}", csp_nonce)
      end)

    conn
    |> Plug.Conn.put_private(:csp_nonce, csp_nonce)
    |> Phoenix.Controller.put_secure_browser_headers(%{
      "content-security-policy" => Enum.join(policy, "; ")
    })
  end

  defp maybe_put_sts_header(conn) do
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
