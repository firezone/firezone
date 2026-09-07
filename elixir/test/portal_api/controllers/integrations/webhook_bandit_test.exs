defmodule PortalAPI.Integrations.WebhookBanditTest do
  use ExUnit.Case, async: true

  # Plug.Test does not enforce Bandit's connection usage counter. Exercise the
  # controllers over HTTP so discarding the conn returned by read_body raises.
  defmodule WebhookPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      Portal.Config.put_env_override(:portal, Portal.AzureCommunicationServices,
        event_grid_webhook_signing_secret: "acs-secret"
      )

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
    %{url: "http://127.0.0.1:#{port}", port: port}
  end

  for {name, path, headers, body, status, response} <- [
        {"Entra invalid JSON", "/entra", [], "{", 400, "Bad Request: invalid JSON"},
        {"Entra missing notifications", "/entra", [], "{}", 400,
         "Bad Request: missing notifications"},
        {"Entra oversized batch", "/entra", [], JSON.encode!(%{value: List.duplicate(%{}, 1001)}),
         413, "Request Entity Too Large: too many notifications"},
        {"Stripe missing timestamp", "/stripe", [{"stripe-signature", "v1=invalid"}], "{}",
         400, "Bad Request: missing timestamp"},
        {"Stripe missing signatures", "/stripe", [{"stripe-signature", "t=0"}], "{}",
         400, "Bad Request: missing signatures"},
        {"Stripe expired signature", "/stripe", [{"stripe-signature", "t=0,v1=invalid"}], "{}",
         400, "Bad Request: expired signature"},
        {"ACS invalid JSON", "/acs", [{"aeg-event-type", "Notification"}], "{", 400,
         "Bad Request: invalid JSON"},
        {"ACS invalid secret", "/acs", [{"aeg-event-type", "Notification"}], "[]", 401,
         "Unauthorized"},
        {"ACS invalid validation event", "/acs", [{"aeg-event-type", "SubscriptionValidation"}],
         "[]", 400, "Bad Request: invalid validation event"},
        {"ACS unsupported event", "/acs", [{"aeg-event-type", "Unknown"}], "[]", 400,
         "Bad Request: unsupported aeg-event-type"},
        {"ACS unsubscribe", "/acs", [{"aeg-event-type", "Unsubscribe"}], "[]", 200, ""},
        {"ACS dispatch failure", "/acs",
         [{"aeg-event-type", "Notification"}, {"aeg-sas-key", "acs-secret"}],
         JSON.encode!([%{eventType: "Microsoft.Communication.EmailDeliveryReportReceived", data: "not-a-map"}]),
         500, "Internal Error"}
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

  test "Stripe rejects an invalid signature after reading the body", %{url: url} do
    timestamp = System.system_time(:second)

    response =
      Finch.build(:post, url <> "/stripe", [{"stripe-signature", "t=#{timestamp},v1=invalid"}], "{}")
      |> Finch.request!(Req.Finch)

    assert response.status == 400
    assert response.body == "Bad Request: invalid signature"
  end

  test "Stripe returns its fallback response for signed invalid JSON", %{url: url} do
    timestamp = System.system_time(:second)
    body = "{"
    secret = Portal.Billing.fetch_webhook_signing_secret!()
    signature = PortalAPI.Integrations.Stripe.WebhookController.sign(timestamp, secret, body)

    response =
      Finch.build(:post, url <> "/stripe", [{"stripe-signature", "t=#{timestamp},v1=#{signature}"}], body)
      |> Finch.request!(Req.Finch)

    assert response.status == 500
    # Bandit also returns 500 on a stale conn; check the controller's body.
    assert response.body == "Internal Error"
  end

  for {path, headers, body} <- [
        {"/entra", "", "{"},
        {"/stripe", "stripe-signature: v1=invalid\r\n", "{}"},
        {"/acs", "aeg-event-type: Notification\r\n", "{"}
      ] do
    test "#{path} preserves the next request on the same connection", %{port: port} do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok = :gen_tcp.send(socket, [
        "POST ", unquote(path), " HTTP/1.1\r\nHost: localhost\r\n",
        unquote(headers), "Content-Length: ", Integer.to_string(byte_size(unquote(body))),
        "\r\n\r\n", unquote(body),
        "POST /entra?validationToken=still-alive HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      ])

      response = receive_until_closed(socket, "")
      assert response =~ "HTTP/1.1 400"
      assert response =~ "HTTP/1.1 200"
      assert String.ends_with?(response, "still-alive")
      refute response =~ "HTTP/1.1 500"
    end
  end

  defp receive_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_until_closed(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("HTTP connection failed: #{inspect(reason)}")
    end
  end
end
