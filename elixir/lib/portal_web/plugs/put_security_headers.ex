defmodule PortalWeb.Plugs.PutSecurityHeaders do
  @behaviour Plug

  @config Application.compile_env!(:portal, __MODULE__)
  @default_csp_policy Keyword.fetch!(@config, :csp_policy)
  @live_reload_frame_csp_policy Keyword.get(@config, :live_reload_frame_csp_policy, false)

  @x_frame_options "SAMEORIGIN"

  @permissions_policy [
    "browsing-topics=()",
    "camera=()",
    "geolocation=()",
    "microphone=()",
    "payment=()",
    "usb=()"
  ]
  |> Enum.join(", ")

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    csp_nonce = Portal.Crypto.random_token(16)

    csp_policy =
      conn
      |> csp_policy_for()
      |> interpolate_nonce(csp_nonce)
      |> Enum.join("; ")

    conn
    |> Plug.Conn.put_private(:csp_nonce, csp_nonce)
    |> Plug.Conn.assign(:csp_nonce, csp_nonce)
    |> Phoenix.Controller.put_secure_browser_headers(headers(csp_policy))
  end

  def headers(csp_policy) do
    %{
      "content-security-policy" => csp_policy,
      "permissions-policy" => @permissions_policy,
      "x-frame-options" => @x_frame_options
    }
  end

  if @live_reload_frame_csp_policy do
    defp csp_policy_for(conn) do
      if String.starts_with?(conn.request_path, "/phoenix/live_reload/frame") do
        @live_reload_frame_csp_policy
      else
        @default_csp_policy
      end
    end
  else
    defp csp_policy_for(_conn), do: @default_csp_policy
  end

  defp interpolate_nonce(policy, nonce) do
    Enum.map(policy, &String.replace(&1, "${nonce}", nonce))
  end
end
