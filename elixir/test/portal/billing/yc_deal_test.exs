defmodule Portal.Billing.YCDealTest do
  use Portal.DataCase, async: true

  alias Portal.Billing.Stripe.APIClient
  alias Portal.Billing.YCDeal

  describe "enforce_cap/1" do
    test "does nothing for invoices without discounts" do
      Req.Test.stub(APIClient, fn _conn -> flunk("Stripe should not be called") end)

      assert YCDeal.enforce_cap(invoice("in_1", [])) == :ok
    end

    test "does nothing while YC discounts stay under the cap" do
      stub_stripe(
        invoices: [paid_invoice("in_1", [yc_discount(30_000, "70000")])],
        items: []
      )

      assert YCDeal.enforce_cap(invoice("in_1", [%{"amount" => 30_000}])) == :ok
      refute_received {:stripe, "DELETE", _path, _conn, _params}
      refute_received {:stripe, "POST", _path, _conn, _params}
    end

    test "ignores discounts from coupons without a YC cap" do
      stub_stripe(
        invoices: [paid_invoice("in_1", [discount(900_000, %{})])],
        items: []
      )

      assert YCDeal.enforce_cap(invoice("in_1", [%{"amount" => 900_000}])) == :ok
      refute_received {:stripe, "GET", "/v1/invoiceitems", _conn, _params}
    end

    test "removes the coupon and bills the excess once the cap is passed" do
      stub_stripe(
        invoices: [
          paid_invoice("in_2", [yc_discount(50_000, "70000")]),
          paid_invoice("in_1", [yc_discount(30_000, "70000")]),
          %{"status" => "void", "total_discount_amounts" => [yc_discount(500_000, "70000")]}
        ],
        items: []
      )

      assert YCDeal.enforce_cap(invoice("in_2", [%{"amount" => 50_000}])) == :ok

      assert_received {:stripe, "DELETE", "/v1/subscriptions/sub_1/discount", _conn, _params}
      assert_received {:stripe, "POST", "/v1/invoiceitems", conn, params}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["yc-deal-overage-in_2-10000"]

      assert params == %{
               "customer" => "cus_1",
               "subscription" => "sub_1",
               "amount" => "10000",
               "currency" => "usd",
               "description" => "YC deal discount beyond the deal's limit",
               "metadata[yc_deal_overage]" => "true"
             }
    end

    test "uses the highest cap when the customer has both YC coupons" do
      stub_stripe(
        invoices: [
          paid_invoice("in_2", [yc_discount(30_000, "40000")]),
          paid_invoice("in_1", [yc_discount(30_000, "70000")])
        ],
        items: []
      )

      assert YCDeal.enforce_cap(invoice("in_2", [%{"amount" => 30_000}])) == :ok
      refute_received {:stripe, "POST", "/v1/invoiceitems", _conn, _params}
    end

    test "does not bill excess that was already billed" do
      stub_stripe(
        invoices: [paid_invoice("in_1", [yc_discount(90_000, "70000")])],
        items: [%{"amount" => 20_000, "metadata" => %{"yc_deal_overage" => "true"}}]
      )

      assert YCDeal.enforce_cap(invoice("in_1", [%{"amount" => 90_000}])) == :ok
      refute_received {:stripe, "POST", "/v1/invoiceitems", _conn, _params}
    end

    test "still bills the excess when the coupon was already removed" do
      stub_stripe(
        invoices: [paid_invoice("in_1", [yc_discount(90_000, "70000")])],
        items: [],
        delete_status: 404
      )

      assert YCDeal.enforce_cap(invoice("in_1", [%{"amount" => 90_000}])) == :ok
      assert_received {:stripe, "POST", "/v1/invoiceitems", _conn, %{"amount" => "20000"}}
    end

    test "returns an error when the invoice is not in the customer's invoices" do
      stub_stripe(
        invoices: [paid_invoice("in_1", [yc_discount(90_000, "70000")])],
        items: []
      )

      assert YCDeal.enforce_cap(invoice("in_2", [%{"amount" => 90_000}])) ==
               {:error, :invoice_not_listed}

      refute_received {:stripe, "POST", "/v1/invoiceitems", _conn, _params}
    end

    test "returns an error when Stripe fails so the event is retried" do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:error, {400, _}} = YCDeal.enforce_cap(invoice("in_1", [%{"amount" => 1}]))
    end
  end

  defp stub_stripe(opts) do
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe, conn.method, conn.request_path, conn, URI.decode_query(body)})

      case {conn.method, conn.request_path} do
        {"GET", "/v1/invoices"} ->
          Req.Test.json(conn, %{"has_more" => false, "data" => opts[:invoices]})

        {"GET", "/v1/invoiceitems"} ->
          Req.Test.json(conn, %{"has_more" => false, "data" => opts[:items]})

        {"DELETE", _path} ->
          conn
          |> Plug.Conn.put_status(Keyword.get(opts, :delete_status, 200))
          |> Req.Test.json(%{"deleted" => true})

        {"POST", "/v1/invoiceitems"} ->
          Req.Test.json(conn, %{"id" => "ii_1"})
      end
    end)
  end

  # Events use the account's API version, which may not have `subscription`
  # or `currency` on the invoice, so the event only carries what is read from it.
  defp invoice(id, discounts) do
    %{"id" => id, "customer" => "cus_1", "total_discount_amounts" => discounts}
  end

  defp paid_invoice(id, discounts) do
    %{
      "id" => id,
      "status" => "paid",
      "customer" => "cus_1",
      "subscription" => "sub_1",
      "currency" => "usd",
      "total_discount_amounts" => discounts
    }
  end

  defp yc_discount(amount, cap), do: discount(amount, %{"yc_deal_cap" => cap})

  defp discount(amount, metadata) do
    %{"amount" => amount, "discount" => %{"coupon" => %{"metadata" => metadata}}}
  end
end
