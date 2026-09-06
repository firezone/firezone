defmodule PortalAPI.Integrations.WebhookBanditTest do
  use ExUnit.Case, async: true

  # Plug.Test does not enforce Bandit's connection usage counter. Exercise the
  # controllers over HTTP so discarding the conn returned by read_body raises.
  defmodule WebhookPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      controller =
        case conn.request_path do
          "/entra" -> PortalAPI.Integrations.Entra.WebhookController
          "/stripe" -> PortalAPI.Integrations.Stripe.WebhookController
          "/acs" -> PortalAPI.Integrations.AzureCommunicationServices.WebhookController
        end

      controller.handle_webhook(conn, %{})
    end
  end

  setup do
    server =
      start_supervised!({Bandit,
       plug: WebhookPlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  for {name, path, headers, body, status, response} <- [
        {"Entra invalid JSON", "/entra", [], "{", 400, "Bad Request: invalid JSON"},
        {"Entra missing notifications", "/entra", [], "{}", 400,
         "Bad Request: missing notifications"},
        {"Entra oversized batch", "/entra", [], JSON.encode!(%{value: List.duplicate(%{}, 1001)}),
         413, "Request Entity Too Large: too many notifications"},
        {"Stripe missing timestamp", "/stripe", [{"stripe-signature", "v1=invalid"}], "{}",
         400, "Bad Request: missing timestamp"},
        {"Stripe expired signature", "/stripe", [{"stripe-signature", "t=0,v1=invalid"}], "{}",
         400, "Bad Request: expired signature"},
        {"ACS invalid JSON", "/acs", [{"aeg-event-type", "Notification"}], "{", 400,
         "Bad Request: invalid JSON"}
      ] do
    test name, %{url: url} do
      response =
        Finch.build(:post, url <> unquote(path), unquote(headers), unquote(body))
        |> Finch.request!(Req.Finch)

      assert response.status == unquote(status)
      assert response.body == unquote(response)
    end
  end

  for {path, headers, size} <- [
        {"/entra", [], 1_100_000},
        {"/stripe", [{"stripe-signature", "v1=invalid"}], 1_100_000},
        {"/acs", [{"aeg-event-type", "Notification"}], 8_100_000}
      ] do
    test "#{path} rejects an oversized body using the updated conn", %{url: url} do
      response =
        Finch.build(:post, url <> unquote(path), unquote(headers), String.duplicate("x", unquote(size)))
        |> Finch.request!(Req.Finch)

      assert response.status == 413
      assert response.body == "Request Entity Too Large"
    end
  end
end
