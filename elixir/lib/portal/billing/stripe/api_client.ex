defmodule Portal.Billing.Stripe.APIClient do
  use Supervisor
  require Logger

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

    request_with_retry(api_token, :post, "customers", body)
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

    request_with_retry(api_token, :post, "customers/#{customer_id}", body)
  end

  def fetch_customer(api_token, customer_id) do
    request_with_retry(api_token, :get, "customers/#{customer_id}", "")
  end

  def list_all_subscriptions(api_token, page_after \\ nil, acc \\ []) do
    query_params =
      if page_after do
        "?starting_after=#{page_after}"
      else
        ""
      end

    case request_with_retry(api_token, :get, "subscriptions#{query_params}", "") do
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
    request_with_retry(api_token, :get, "products/#{product_id}", "")
  end

  def create_billing_portal_session(api_token, customer_id, return_url) do
    body = URI.encode_query(%{"customer" => customer_id, "return_url" => return_url}, :www_form)
    request_with_retry(api_token, :post, "billing_portal/sessions", body)
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

    request_with_retry(api_token, :post, "subscriptions", body)
  end

  def request_with_retry(api_token, method, path, body) do
    max_retries = fetch_retry_config(:max_retries, 3)
    base_delay = fetch_retry_config(:base_delay_ms, 1000)
    max_delay = fetch_retry_config(:max_delay_ms, 10_000)

    do_request_with_retry(api_token, method, path, body, 0, max_retries, base_delay, max_delay)
  end

  defp do_request_with_retry(
         api_token,
         method,
         path,
         body,
         attempt,
         max_retries,
         base_delay,
         max_delay
       ) do
    case request(api_token, method, path, body) do
      {:ok, response} ->
        {:ok, response}

      {:error, {429, response}} when attempt < max_retries ->
        delay = calculate_delay(attempt, base_delay, max_delay)

        Logger.warning(
          "Rate limited by Stripe API (429), retrying request.",
          request_delay: "#{delay}ms",
          attempt_num: "#{attempt + 1} of #{max_retries}",
          url_path: path,
          response: inspect(response)
        )

        Process.sleep(delay)

        do_request_with_retry(
          api_token,
          method,
          path,
          body,
          attempt + 1,
          max_retries,
          base_delay,
          max_delay
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp calculate_delay(attempt, base_delay, max_delay) do
    # Exponential backoff with jitter
    exponential_delay = base_delay * :math.pow(2, attempt)
    jitter = :rand.uniform() * 0.1 * exponential_delay

    (exponential_delay + jitter)
    |> round()
    |> min(max_delay)
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
        {:ok, JSON.decode!(response)}

      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Finch.Response{body: response, status: status}} ->
        case JSON.decode(response) do
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
    Portal.Config.fetch_env!(:domain, __MODULE__)
    |> Keyword.fetch!(key)
  end

  defp fetch_retry_config(key, default) do
    config = Portal.Config.fetch_env!(:domain, __MODULE__)

    case Keyword.get(config, :retry_config) do
      nil -> default
      retry_config -> Keyword.get(retry_config, key, default)
    end
  end
end
