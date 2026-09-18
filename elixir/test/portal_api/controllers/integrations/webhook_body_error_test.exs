defmodule PortalAPI.Integrations.WebhookBodyErrorTest do
  use ExUnit.Case, async: true

  # Unlike successful and partial reads, Plug's {:error, reason} result has
  # no updated conn. Inject that adapter result without racing a socket timeout.
  defmodule ReadErrorAdapter do
    def read_req_body(%{read_error: reason}, _opts), do: {:error, reason}
    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  end

  for {controller, headers, status, body} <- [
        {PortalAPI.Integrations.Entra.WebhookController, [], 400, "Bad Request"},
        {PortalAPI.Integrations.Stripe.WebhookController, [{"stripe-signature", "v1=invalid"}],
         500, "Internal Error"},
        {PortalAPI.Integrations.AzureCommunicationServices.WebhookController,
         [{"aeg-event-type", "Notification"}], 500, "Internal Error"}
      ],
      reason <- [:timeout, :closed] do
    test "#{inspect(controller)} handles #{reason} while reading the body" do
      conn = Plug.Test.conn(:post, "/", "{}")
      {Plug.Adapters.Test.Conn, state} = conn.adapter

      conn = %{
        conn
        | adapter: {ReadErrorAdapter, Map.put(state, :read_error, unquote(reason))},
          req_headers: unquote(headers)
      }

      conn = unquote(controller).handle_webhook(conn, %{})

      assert conn.state == :sent
      assert conn.status == unquote(status)
      assert conn.resp_body == unquote(body)
    end
  end
end
