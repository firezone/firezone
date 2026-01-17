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

  def update_customer(api_token, customer_id, name, metadata) do
    metadata_params =
      for {key, value} <- metadata, into: %{} do
        {"metadata[#{key}]", value}
      end

    body =
      metadata_params
      |> Map.put("name", name)
      |> URI.encode_query(:www_form)

    request(api_token, :post, "customers/#{customer_id}", body)
  end

  def fetch_customer(api_token, customer_id) do
    request(api_token, :get, "customers/#{customer_id}", "")
  end

  def list_all_subscriptions(api_token, page_after \\ nil, acc \\ []) do
    query_params =
      if page_after do
        "?starting_after=#{page_after}"
      else
        ""
      end

    case request(api_token, :get, "subscriptions#{query_params}", "") do
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
    request(api_token, :get, "products/#{product_id}", "")
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

  def request(api_token, method, path, body) do
    endpoint = fetch_config!(:endpoint)
    url = "#{endpoint}/v1/#{path}"

    headers = [
      {"authorization", "Bearer #{api_token}"},
      {"content-type", "application/x-www-form-urlencoded"},
      {"stripe-version", "2023-10-16"}
    ]

    req_opts =
      [method: method, url: url, headers: headers, body: body]
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
