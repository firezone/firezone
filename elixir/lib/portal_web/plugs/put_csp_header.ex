defmodule PortalWeb.Plugs.PutCSPHeader do
  @behaviour Plug

  @config Application.compile_env!(:portal, __MODULE__)
  @default_policy Keyword.fetch!(@config, :csp_policy)
  @live_reload_frame_policy Keyword.get(@config, :live_reload_frame_csp_policy, false)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    csp_nonce = Portal.Crypto.random_token(16)

    policy =
      conn
      |> policy_for()
      |> interpolate_nonce(csp_nonce)
      |> Enum.join("; ")

    conn
    |> Plug.Conn.put_private(:csp_nonce, csp_nonce)
    |> Plug.Conn.assign(:csp_nonce, csp_nonce)
    |> Phoenix.Controller.put_secure_browser_headers(%{
      "content-security-policy" => policy
    })
  end

  defp policy_for(conn) do
    if live_reload_frame?(conn) and @live_reload_frame_policy do
      @live_reload_frame_policy
    else
      @default_policy
    end
  end

  defp interpolate_nonce(policy, nonce) do
    Enum.map(policy, &String.replace(&1, "${nonce}", nonce))
  end

  defp live_reload_frame?(conn) do
    String.starts_with?(conn.request_path, "/phoenix/live_reload/frame")
  end
end
