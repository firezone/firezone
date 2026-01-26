defmodule PortalAPI.Plugs.Auth do
  import Plug.Conn

  def init(opts), do: Keyword.get(opts, :context_type, :api_client)

  def call(conn, context_type) do
    user_agent = conn.assigns[:user_agent]
    remote_ip = conn.remote_ip

    context =
      Portal.Authentication.Context.build(remote_ip, user_agent, conn.req_headers, context_type)

    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, subject} <- Portal.Authentication.authenticate(encoded_token, context) do
      assign(conn, :subject, subject)
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.put_view(json: PortalAPI.ErrorJSON)
        |> Phoenix.Controller.render(:"401")
        |> halt()
    end
  end
end
