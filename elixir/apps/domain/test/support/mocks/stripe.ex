defmodule Domain.Mocks.Stripe do
  alias Domain.Billing.Stripe.APIClient

  def override_endpoint_url(url) do
    config = Domain.Config.fetch_env!(:domain, APIClient)
    config = Keyword.put(config, :endpoint, url)
    Domain.Config.put_env_override(:domain, APIClient, config)
  end

  def mock_create_customer_endpoint(bypass, account, resp \\ %{}) do
    customers_endpoint_path = "v1/customers"

    test_pid = self()

    Bypass.expect(bypass, "POST", customers_endpoint_path, fn conn ->
      # Store test PID in connection for rate limiting
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          conn = fetch_request_params(conn)
          send(test_pid, {:bypass_request, conn})

          email = Map.get(conn.params, "email", "foo@example.com")

          resp =
            Map.merge(
              customer_object("cus_NffrFeUfNV2Hib", account.name, email, %{
                "account_id" => account.id
              }),
              resp
            )

          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_update_customer_endpoint(bypass, account, resp \\ %{}) do
    customer_endpoint_path = "v1/customers/#{account.metadata.stripe.customer_id}"

    resp =
      Map.merge(
        customer_object(account.metadata.stripe.customer_id, account.name, "foo@example.com", %{
          "account_id" => account.id
        }),
        resp
      )

    test_pid = self()

    Bypass.expect(bypass, "POST", customer_endpoint_path, fn conn ->
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          conn = fetch_request_params(conn)
          send(test_pid, {:bypass_request, conn})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_fetch_customer_endpoint(bypass, account, resp \\ %{}) do
    customer_endpoint_path = "v1/customers/#{account.metadata.stripe.customer_id}"

    resp =
      Map.merge(
        customer_object(account.metadata.stripe.customer_id, account.name, "foo@example.com", %{
          "account_id" => account.id
        }),
        resp
      )

    test_pid = self()

    Bypass.expect(bypass, "GET", customer_endpoint_path, fn conn ->
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:bypass_request, conn})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_fetch_product_endpoint(bypass, product_id, resp \\ %{}) do
    product_endpoint_path = "v1/products/#{product_id}"

    resp =
      Map.merge(
        %{
          "id" => product_id,
          "object" => "product",
          "active" => true,
          "created" => 1_678_833_149,
          "default_price" => nil,
          "description" => nil,
          "images" => [],
          "features" => [],
          "livemode" => false,
          "metadata" => %{},
          "name" => "Enterprise",
          "package_dimensions" => nil,
          "shippable" => nil,
          "statement_descriptor" => nil,
          "tax_code" => nil,
          "unit_label" => nil,
          "updated" => 1_678_833_149,
          "url" => nil
        },
        resp
      )

    test_pid = self()

    Bypass.expect(bypass, "GET", product_endpoint_path, fn conn ->
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          send(test_pid, {:bypass_request, conn})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_create_billing_session_endpoint(bypass, account, resp \\ %{}) do
    customers_endpoint_path = "v1/billing_portal/sessions"

    resp =
      Map.merge(
        %{
          "id" => "bps_1MrSjzLkdIwHu7ixex0IvU9b",
          "object" => "billing_portal.session",
          "configuration" => "bpc_1MAhNDLkdIwHu7ixckACO1Jq",
          "created" => 1_680_210_639,
          "customer" => account.metadata.stripe.customer_id,
          "flow" => nil,
          "livemode" => false,
          "locale" => nil,
          "on_behalf_of" => nil,
          "return_url" => "https://example.com/account",
          "url" =>
            "https://billing.stripe.com/p/session/test_YWNjdF8xTTJKVGtMa2RJd0h1N2l4LF9OY2lBYjJXcHY4a2NPck96UjBEbFVYRnU5bjlwVUF50100BUtQs3bl"
        },
        resp
      )

    test_pid = self()

    Bypass.expect(bypass, "POST", customers_endpoint_path, fn conn ->
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          conn = fetch_request_params(conn)
          send(test_pid, {:bypass_request, conn})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  def mock_create_subscription_endpoint(bypass, resp \\ %{}) do
    customers_endpoint_path = "v1/subscriptions"

    resp =
      Map.merge(
        subscription_object("cus_NffrFeUfNV2Hib", %{}, %{}, 1),
        resp
      )

    test_pid = self()

    Bypass.expect(bypass, "POST", customers_endpoint_path, fn conn ->
      conn = %{conn | private: Map.put(conn.private, :test_pid, test_pid)}

      case check_rate_limit(conn) do
        {:rate_limited, response} ->
          response

        :ok ->
          conn = Plug.Conn.fetch_query_params(conn)
          conn = fetch_request_params(conn)
          send(test_pid, {:bypass_request, conn})
          Plug.Conn.send_resp(conn, 200, Jason.encode!(resp))
      end
    end)

    override_endpoint_url("http://localhost:#{bypass.port}")

    bypass
  end

  # Rate limiting control functions
  def enable_rate_limiting(rate_limit_count \\ 2) do
    ensure_ets_table()
    test_pid = self()

    state = %{
      rate_limit_enabled: true,
      rate_limit_count: rate_limit_count,
      request_count: 0
    }

    :ets.insert(:stripe_mock_state, {test_pid, state})
  end

  def disable_rate_limiting do
    ensure_ets_table()
    test_pid = self()
    :ets.delete(:stripe_mock_state, test_pid)
  end

  def reset_rate_limit_counter do
    ensure_ets_table()
    test_pid = self()

    case :ets.lookup(:stripe_mock_state, test_pid) do
      [{^test_pid, state}] ->
        updated_state = Map.put(state, :request_count, 0)
        :ets.insert(:stripe_mock_state, {test_pid, updated_state})

      [] ->
        :ok
    end
  end

  def get_request_count do
    ensure_ets_table()
    test_pid = self()

    case :ets.lookup(:stripe_mock_state, test_pid) do
      [{^test_pid, state}] -> Map.get(state, :request_count, 0)
      [] -> 0
    end
  end

  # Rate limiting with flexible patterns
  def configure_rate_limiting(pattern) when is_function(pattern, 1) do
    ensure_ets_table()
    test_pid = self()

    state = %{
      rate_limit_pattern: pattern,
      request_count: 0
    }

    :ets.insert(:stripe_mock_state, {test_pid, state})
  end

  def configure_rate_limiting(opts) when is_list(opts) do
    ensure_ets_table()
    test_pid = self()
    fail_on_attempts = Keyword.get(opts, :fail_on_attempts, [1, 2])
    pattern = fn count -> count in fail_on_attempts end

    state = %{
      rate_limit_pattern: pattern,
      request_count: 0
    }

    :ets.insert(:stripe_mock_state, {test_pid, state})
  end

  defp ensure_ets_table do
    case :ets.whereis(:stripe_mock_state) do
      :undefined ->
        :ets.new(:stripe_mock_state, [:named_table, :public, :set])

      _table ->
        :ok
    end
  end

  defp check_rate_limit(conn) do
    ensure_ets_table()

    # Get the test process PID from the connection
    test_pid = get_test_pid(conn)

    # Get current state and increment request count
    {current_count, state} =
      case :ets.lookup(:stripe_mock_state, test_pid) do
        [{^test_pid, existing_state}] ->
          new_count = Map.get(existing_state, :request_count, 0) + 1
          updated_state = Map.put(existing_state, :request_count, new_count)
          :ets.insert(:stripe_mock_state, {test_pid, updated_state})
          {new_count, updated_state}

        [] ->
          {1, %{request_count: 1}}
      end

    cond do
      # Check for custom pattern function
      pattern_fn = Map.get(state, :rate_limit_pattern) ->
        if pattern_fn.(current_count) do
          {:rate_limited, send_rate_limit_response(conn)}
        else
          :ok
        end

      # Check for simple rate limiting
      Map.get(state, :rate_limit_enabled) ->
        rate_limit_count = Map.get(state, :rate_limit_count, 2)

        if current_count <= rate_limit_count do
          {:rate_limited, send_rate_limit_response(conn)}
        else
          :ok
        end

      true ->
        :ok
    end
  end

  defp get_test_pid(conn) do
    # Look for the test PID in the connection's private assigns
    case Map.get(conn.private, :test_pid) do
      nil ->
        # Fallback: try to find any active test process
        case :ets.first(:stripe_mock_state) do
          :"$end_of_table" -> self()
          pid -> pid
        end

      pid ->
        pid
    end
  end

  defp send_rate_limit_response(conn) do
    error_response = %{
      "error" => %{
        "code" => "lock_timeout",
        "doc_url" => "https://stripe.com/docs/error-codes/lock-timeout",
        "message" => "Error message here",
        "request_log_url" => "https://dashboard.stripe.com/logs/req_ABC123DEF456",
        "type" => "invalid_request_error"
      }
    }

    conn
    |> Plug.Conn.send_resp(429, Jason.encode!(error_response))
  end

  def customer_object(id, name, email \\ nil, metadata \\ %{}) do
    %{
      "id" => id,
      "object" => "customer",
      "address" => nil,
      "balance" => 0,
      "created" => 1_680_893_993,
      "currency" => nil,
      "default_source" => nil,
      "delinquent" => false,
      "description" => nil,
      "discount" => nil,
      "email" => email,
      "invoice_prefix" => "0759376C",
      "invoice_settings" => %{
        "custom_fields" => nil,
        "default_payment_method" => nil,
        "footer" => nil,
        "rendering_options" => nil
      },
      "livemode" => false,
      "metadata" => metadata,
      "name" => name,
      "next_invoice_sequence" => 1,
      "phone" => nil,
      "preferred_locales" => [],
      "shipping" => nil,
      "tax_exempt" => "none",
      "test_clock" => nil
    }
  end

  def subscription_object(customer_id, subscription_metadata, plan_metadata, quantity) do
    %{
      "id" => "sub_1MowQVLkdIwHu7ixeRlqHVzs",
      "object" => "subscription",
      "application" => nil,
      "application_fee_percent" => nil,
      "automatic_tax" => %{
        "enabled" => false,
        "liability" => nil
      },
      "billing_cycle_anchor" => 1_679_609_767,
      "billing_thresholds" => nil,
      "cancel_at" => nil,
      "cancel_at_period_end" => false,
      "canceled_at" => nil,
      "cancellation_details" => %{
        "comment" => nil,
        "feedback" => nil,
        "reason" => nil
      },
      "collection_method" => "charge_automatically",
      "created" => 1_679_609_767,
      "currency" => "usd",
      "current_period_end" => 1_682_288_167,
      "current_period_start" => 1_679_609_767,
      "customer" => customer_id,
      "days_until_due" => nil,
      "default_payment_method" => nil,
      "default_source" => nil,
      "default_tax_rates" => [],
      "description" => nil,
      "discount" => nil,
      "ended_at" => nil,
      "invoice_settings" => %{
        "issuer" => %{
          "type" => "self"
        }
      },
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "id" => "si_Na6dzxczY5fwHx",
            "object" => "subscription_item",
            "billing_thresholds" => nil,
            "created" => 1_679_609_768,
            "metadata" => %{},
            "plan" => %{
              "id" => "price_1MowQULkdIwHu7ixraBm864M",
              "object" => "plan",
              "active" => true,
              "aggregate_usage" => nil,
              "amount" => 1000,
              "amount_decimal" => "1000",
              "billing_scheme" => "per_unit",
              "created" => 1_679_609_766,
              "currency" => "usd",
              "interval" => "month",
              "interval_count" => 1,
              "livemode" => false,
              "metadata" => plan_metadata,
              "nickname" => nil,
              "product" => "prod_Na6dGcTsmU0I4R",
              "tiers_mode" => nil,
              "transform_usage" => nil,
              "trial_period_days" => nil,
              "usage_type" => "licensed"
            },
            "price" => %{
              "id" => "price_1MowQULkdIwHu7ixraBm864M",
              "object" => "price",
              "active" => true,
              "billing_scheme" => "per_unit",
              "created" => 1_679_609_766,
              "currency" => "usd",
              "custom_unit_amount" => nil,
              "livemode" => false,
              "lookup_key" => nil,
              "metadata" => %{},
              "nickname" => nil,
              "product" => "prod_Na6dGcTsmU0I4R",
              "recurring" => %{
                "aggregate_usage" => nil,
                "interval" => "month",
                "interval_count" => 1,
                "trial_period_days" => nil,
                "usage_type" => "licensed"
              },
              "tax_behavior" => "unspecified",
              "tiers_mode" => nil,
              "transform_quantity" => nil,
              "type" => "recurring",
              "unit_amount" => 1000,
              "unit_amount_decimal" => "1000"
            },
            "quantity" => quantity,
            "subscription" => "sub_1MowQVLkdIwHu7ixeRlqHVzs",
            "tax_rates" => []
          }
        ],
        "has_more" => false,
        "total_count" => 1,
        "url" => "/v1/subscription_items?subscription=sub_1MowQVLkdIwHu7ixeRlqHVzs"
      },
      "latest_invoice" => "in_1MowQWLkdIwHu7ixuzkSPfKd",
      "livemode" => false,
      "metadata" => subscription_metadata,
      "next_pending_invoice_item_invoice" => nil,
      "on_behalf_of" => nil,
      "pause_collection" => nil,
      "payment_settings" => %{
        "payment_method_options" => nil,
        "payment_method_types" => nil,
        "save_default_payment_method" => "off"
      },
      "pending_invoice_item_interval" => nil,
      "pending_setup_intent" => nil,
      "pending_update" => nil,
      "quantity" => 1,
      "schedule" => nil,
      "start_date" => 1_679_609_767,
      "status" => "active",
      "test_clock" => nil,
      "transfer_data" => nil,
      "trial_end" => nil,
      "trial_settings" => %{
        "end_behavior" => %{
          "missing_payment_method" => "create_invoice"
        }
      },
      "trial_start" => nil
    }
  end

  def build_event(type, object) do
    %{
      "id" => "evt_1NG8Du2eZvKYlo2CUI79vXWy",
      "object" => "event",
      "api_version" => "2019-02-19",
      "created" => 1_686_089_970,
      "data" => %{
        "object" => object
      },
      "livemode" => false,
      "pending_webhooks" => 0,
      "request" => %{
        "id" => nil,
        "idempotency_key" => nil
      },
      "type" => type
    }
  end

  defp fetch_request_params(conn) do
    opts =
      Plug.Parsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library()
      )

    Plug.Parsers.call(conn, opts)
  end
end
