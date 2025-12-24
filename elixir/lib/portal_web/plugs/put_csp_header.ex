defmodule PortalWeb.Plugs.PutCSPHeader do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    csp_nonce = Portal.Crypto.random_token(8)

    policy =
      Application.fetch_env!(:portal, __MODULE__)
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
end
