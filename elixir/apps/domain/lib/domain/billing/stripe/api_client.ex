defmodule Domain.Billing.Stripe.APIClient do
  use Supervisor

  @pool_name __MODULE__.Finch

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Finch,
       name: @pool_name,
       pools: %{
         default: pool_opts()
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_opts do
    transport_opts = fetch_config!(:finch_transport_opts)
    [conn_opts: [transport_opts: transport_opts]]
  end

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
    uri = URI.parse("#{endpoint}/v1/#{path}")

    headers = [
      {"Authorization", "Bearer #{api_token}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Stripe-Version", "2023-10-16"}
    ]

    Finch.build(method, uri, headers, body)
    |> Finch.request(@pool_name)
    |> case do
      {:ok, %Finch.Response{body: response, status: status}} when status in 200..299 ->
        {:ok, Jason.decode!(response)}

      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Finch.Response{body: response, status: status}} ->
        case Jason.decode(response) do
          {:ok, json_response} ->
            {:error, {status, json_response}}

          _error ->
            {:error, {status, response}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)

  defp fetch_config!(key) do
    Domain.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(key)
  end
end
