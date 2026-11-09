defmodule Portal.Billing.Stripe.APIClientTest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures
  alias Portal.Billing.Stripe.APIClient
  alias Portal.Mocks.Stripe

  describe "request/4" do
    setup do
      Portal.Config.put_env_override(APIClient,
        endpoint: "https://api.stripe.com",
        req_opts: [plug: {Req.Test, APIClient}, retry_delay: 0]
      )
    end

    test "retries a POST with the same idempotency key" do
      test_pid = self()

      for status <- [429, 503] do
        Req.Test.expect(APIClient, fn conn ->
          send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
          Plug.Conn.send_resp(conn, status, "{}")
        end)
      end

      Req.Test.expect(APIClient, fn conn ->
        send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{"id" => "cus_retried"})
      end)

      assert {:ok, %{"id" => "cus_retried"}} =
               APIClient.create_customer("test_token", "Test", "test@example.com", %{})

      assert_received {:key, [key]}
      assert_received {:key, [^key]}
      assert_received {:key, [^key]}
    end

    test "sends a new idempotency key for each call" do
      test_pid = self()

      Req.Test.stub(APIClient, fn conn ->
        send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{"id" => "cus_test"})
      end)

      assert {:ok, _customer} = APIClient.update_customer_metadata("test_token", "cus_test", %{account_slug: "a"})
      assert {:ok, _customer} = APIClient.update_customer_metadata("test_token", "cus_test", %{account_slug: "b"})

      assert_received {:key, [first]}
      assert_received {:key, [second]}
      assert first != second
    end

    test "sends no idempotency key on a GET" do
      test_pid = self()

      Req.Test.stub(APIClient, fn conn ->
        send(test_pid, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{"id" => "cus_test"})
      end)

      assert {:ok, _customer} = APIClient.fetch_customer("test_token", "cus_test")
      assert_received {:key, []}
    end
  end

  describe "create_customer/4" do
    test "returns customer on success" do
      account = account_fixture()

      Stripe.stub(Stripe.mock_create_customer_endpoint(account))

      assert {:ok, customer} =
               APIClient.create_customer("test_token", account.name, "test@example.com", %{})

      assert customer["object"] == "customer"
      assert customer["name"] == account.name
    end

    test "returns error on server error" do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s|{"error": "Internal Server Error"}|)
      end)

      assert {:error, :retry_later} =
               APIClient.create_customer("test_token", "Test", "test@example.com", %{})
    end

    test "returns error on client error" do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s|{"error": {"message": "Bad request"}}|)
      end)

      assert {:error, {400, _body}} =
               APIClient.create_customer("test_token", "Test", "test@example.com", %{})
    end
  end

  describe "fetch_customer/2" do
    test "returns customer on success" do
      account = account_fixture()

      Stripe.stub([
        {"GET", ~r|/v1/customers/|, 200, Stripe.customer_object("cus_123", account.name)}
      ])

      assert {:ok, customer} = APIClient.fetch_customer("test_token", "cus_123")
      assert customer["id"] == "cus_123"
    end

    test "returns error when customer not found" do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s|{"error": {"message": "No such customer"}}|)
      end)

      assert {:error, {404, _body}} = APIClient.fetch_customer("test_token", "cus_notexist")
    end
  end

  describe "list_all_subscriptions/1" do
    test "returns all subscriptions when no pagination needed" do
      subscription = Stripe.subscription_object("cus_123", %{}, %{}, 1)

      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{"has_more" => false, "data" => [subscription]})
        )
      end)

      assert {:ok, [returned_sub]} = APIClient.list_all_subscriptions("test_token")
      assert returned_sub["id"] == subscription["id"]
    end

    test "paginates to collect all subscriptions" do
      sub1 = Stripe.subscription_object("cus_1", %{}, %{}, 1) |> Map.put("id", "sub_page1")
      sub2 = Stripe.subscription_object("cus_2", %{}, %{}, 1) |> Map.put("id", "sub_page2")

      call_count = :counters.new(1, [])

      Req.Test.stub(APIClient, fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        response =
          if count == 0 do
            %{"has_more" => true, "data" => [sub1]}
          else
            %{"has_more" => false, "data" => [sub2]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(response))
      end)

      assert {:ok, subs} = APIClient.list_all_subscriptions("test_token")
      assert length(subs) == 2
    end
  end

  describe "create_billing_portal_session/3" do
    test "returns session on success" do
      account = account_fixture()

      Stripe.stub(Stripe.mock_create_billing_session_endpoint(account))

      assert {:ok, session} =
               APIClient.create_billing_portal_session(
                 "test_token",
                 account.metadata.stripe.customer_id,
                 "https://example.com/return"
               )

      assert session["object"] == "billing_portal.session"
    end
  end
end
