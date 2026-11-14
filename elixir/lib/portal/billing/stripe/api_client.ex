defmodule Portal.Billing.Stripe.APIClient do
  def create_customer(api_token, name, email, metadata) do
    metadata_params =
      for {key, value} <- metadata, into: %{} do
        {"metadata[#{key}]", value}
      end

    body =
      metadata_params
      |> Map.put("name", name)
      |> put_if_not_nil("email", email)
      |> URI.encode_query(:www_form)

    request(api_token, :post, "customers", body)
  end

  def update_customer_metadata(api_token, customer_id, metadata) do
    body =
      for {key, value} <- metadata, into: %{} do
        {"metadata[#{key}]", value}
      end
      |> URI.encode_query(:www_form)

    request(api_token, :post, "customers/#{customer_id}", body)
  end

  def fetch_customer(api_token, customer_id) do
    request(api_token, :get, "customers/#{customer_id}")
  end

  def list_all_subscriptions(api_token, page_after \\ nil, acc \\ []) do
    query_params =
      if page_after do
        "?starting_after=#{page_after}"
      else
        ""
      end

    case request(api_token, :get, "subscriptions#{query_params}") do
      {:ok, %{"has_more" => true, "data" => data}} ->
        page_after = List.last(data)["id"]
        list_all_subscriptions(api_token, page_after, acc ++ data)

      {:ok, %{"has_more" => false, "data" => data}} ->
        {:ok, acc ++ data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_product(api_token, product_id) do
    request(api_token, :get, "products/#{product_id}")
  end

  # Without a status filter, Stripe lists every subscription that is not canceled.
  def fetch_customer_subscriptions(api_token, customer_id) do
    request(api_token, :get, "subscriptions?customer=#{customer_id}&limit=100")
  end

  def fetch_open_subscription_invoices(api_token, subscription_id) do
    request(api_token, :get, "invoices?subscription=#{subscription_id}&status=open&limit=100")
  end

  def update_invoice_auto_advance(api_token, invoice_id, auto_advance) do
    body = URI.encode_query(%{"auto_advance" => auto_advance}, :www_form)
    request(api_token, :post, "invoices/#{invoice_id}", body)
  end

  def create_billing_portal_session(api_token, customer_id, return_url) do
    body = URI.encode_query(%{"customer" => customer_id, "return_url" => return_url}, :www_form)
    request(api_token, :post, "billing_portal/sessions", body)
  end

  def create_subscription(api_token, customer_id, price_id) do
    body =
      URI.encode_query(
        %{
          "customer" => customer_id,
          "items[0][price]" => price_id
        },
        :www_form
      )

    request(api_token, :post, "subscriptions", body)
  end

  def create_promotion_code(api_token, coupon_id, metadata, idempotency_key) do
    body =
      metadata
      |> Map.new(fn {key, value} -> {"metadata[#{key}]", value} end)
      |> Map.merge(%{"coupon" => coupon_id, "max_redemptions" => 1})
      |> URI.encode_query(:www_form)

    request(api_token, :post, "promotion_codes", body, idempotency_key: idempotency_key)
  end

  def list_all_customer_invoices(api_token, customer_id, page_after \\ nil, acc \\ []) do
    query =
      [
        {"customer", customer_id},
        {"limit", 100},
        {"expand[]", "data.total_discount_amounts.discount"}
      ]
      |> put_if_not_nil_kv("starting_after", page_after)
      |> URI.encode_query(:www_form)

    case request(api_token, :get, "invoices?#{query}") do
      {:ok, %{"has_more" => true, "data" => data}} ->
        list_all_customer_invoices(api_token, customer_id, List.last(data)["id"], acc ++ data)

      {:ok, %{"has_more" => false, "data" => data}} ->
        {:ok, acc ++ data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_all_customer_invoice_items(api_token, customer_id, page_after \\ nil, acc \\ []) do
    query =
      [{"customer", customer_id}, {"limit", 100}]
      |> put_if_not_nil_kv("starting_after", page_after)
      |> URI.encode_query(:www_form)

    case request(api_token, :get, "invoiceitems?#{query}") do
      {:ok, %{"has_more" => true, "data" => data}} ->
        list_all_customer_invoice_items(api_token, customer_id, List.last(data)["id"], acc ++ data)

      {:ok, %{"has_more" => false, "data" => data}} ->
        {:ok, acc ++ data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_invoice_item(api_token, attrs, idempotency_key) do
    body = URI.encode_query(attrs, :www_form)
    request(api_token, :post, "invoiceitems", body, idempotency_key: idempotency_key)
  end

  def delete_subscription_discount(api_token, subscription_id) do
    request(api_token, :delete, "subscriptions/#{subscription_id}/discount")
  end

  def cancel_subscription(api_token, subscription_id) do
    request(api_token, :delete, "subscriptions/#{subscription_id}")
  end

  # Req turns a GET with a body, even an empty one, into a POST.
  def request(api_token, method, path, body \\ nil, opts \\ []) do
    endpoint = fetch_config!(:endpoint)
    url = "#{endpoint}/v1/#{path}"

    headers = [
      {"authorization", "Bearer #{api_token}"},
      {"content-type", "application/x-www-form-urlencoded"},
      {"stripe-version", "2023-10-16"}
    ]

    # Every retry of this call sends the same idempotency key, so Stripe
    # returns the saved result of a POST it already ran instead of running it
    # again, and a retried POST cannot create a second customer or subscription.
    req_opts =
      [
        method: method,
        url: url,
        headers: headers ++ idempotency_key_header(method, opts[:idempotency_key]),
        body: body,
        retry: &retry?/2,
        max_retries: 2
      ]
      |> Keyword.merge(fetch_config(:req_opts) || [])

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stripe replays the saved result of a keyed POST, a 500 included, so only
  # failures where Stripe did not answer, or says a retry can help, are retried.
  # DELETE has no idempotency key and is never retried.
  defp retry?(%Req.Request{method: method}, response_or_exception) when method in [:get, :post] do
    retryable?(response_or_exception)
  end

  defp retry?(_request, _response_or_exception), do: false

  defp retryable?(%Req.Response{status: status} = response) do
    case Req.Response.get_header(response, "stripe-should-retry") do
      ["true"] -> true
      ["false"] -> false
      _ -> status in [409, 429]
    end
  end

  defp retryable?(%Req.TransportError{reason: reason}), do: reason in [:timeout, :econnrefused, :closed]
  defp retryable?(_exception), do: false

  defp idempotency_key_header(:post, nil), do: [{"idempotency-key", Ecto.UUID.generate()}]
  defp idempotency_key_header(:post, key), do: [{"idempotency-key", key}]
  defp idempotency_key_header(_method, _key), do: []

  defp put_if_not_nil_kv(params, _key, nil), do: params
  defp put_if_not_nil_kv(params, key, value), do: params ++ [{key, value}]

  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)

  defp fetch_config!(key) do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(key)
  end

  defp fetch_config(key) do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.get(key)
  end
end
