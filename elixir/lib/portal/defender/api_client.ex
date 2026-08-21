defmodule Portal.Defender.APIClient do
  @moduledoc """
  Client for the Microsoft Defender for Endpoint API.

  Machine inventory has no Microsoft Graph equivalent: the Graph security API
  carries alerts, incidents and hunting queries, not devices. So this talks to
  the classic Defender API, with `Machine.Read.All` granted on WindowsDefenderATP
  rather than on Graph, and does not go through `Portal.Microsoft.Graph.APIClient`
  even though both authenticate the same way against the same Entra tenant.

  Paging is `$top` plus `$skip`, not the `@odata.nextLink` Graph hands back.
  Defender keeps next links for its export endpoints and documents `$top` as
  suppressing them there, so `$top` caps the result set rather than sizing a
  page: `$skip` is what walks past the cap.
  """

  # `$top` accepts up to 10,000, but this is the largest page other Defender
  # clients ask for.
  @page_size 1000

  @doc """
  Gets an access token using the OAuth2 client credentials flow.
  """
  def get_access_token(tenant_id) do
    config = config()
    token_endpoint = "#{config[:token_base_url]}/#{tenant_id}/oauth2/v2.0/token"

    with {:ok, credential} <- client_credential(config) do
      payload =
        %{
          "client_id" => config[:client_id],
          "scope" => config[:token_scope],
          "grant_type" => "client_credentials"
        }
        |> Map.merge(credential)
        |> URI.encode_query()

      Req.post(
        token_endpoint,
        [
          headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
          body: payload
        ] ++ req_opts()
      )
    end
  end

  @doc """
  Credentials for the app registration, shaped for the OIDC verification flow.
  """
  def verification_config do
    config()
    |> Keyword.take([:client_id, :client_secret])
  end

  @doc """
  Streams every page of Defender machines.

  Emits a list per page, or an error tuple that ends the stream.
  """
  def stream_machines(access_token) do
    Stream.resource(
      fn -> 0 end,
      fn
        nil -> {:halt, nil}
        skip -> fetch_page(skip, access_token)
      end,
      fn _state -> :ok end
    )
  end

  # Production authenticates the app with workload identity federation: the
  # portal's managed identity mints a token-exchange assertion, so no secret is
  # stored. A configured client secret (dev and test, which have no managed
  # identity) uses the secret directly.
  defp client_credential(config) do
    case config[:client_secret] do
      secret when is_binary(secret) and secret != "" ->
        {:ok, %{"client_secret" => secret}}

      _ ->
        federated_credential()
    end
  end

  defp federated_credential do
    assertion = Portal.Azure.ManagedIdentity.access_token!("api://AzureADTokenExchange")

    {:ok,
     %{
       "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
       "client_assertion" => assertion
     }}
  rescue
    exception -> {:error, exception}
  end

  defp get(path, query, access_token) do
    Req.get(
      "#{endpoint()}#{path}?#{query}",
      [headers: [{"Authorization", "Bearer #{access_token}"}]] ++ req_opts()
    )
  end

  defp fetch_page(skip, access_token) do
    query = URI.encode_query(%{"$top" => @page_size, "$skip" => skip})

    case get("/api/machines", query, access_token) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_page(body, skip)

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, _reason} = error ->
        {[error], nil}
    end
  end

  defp parse_page(body, skip) do
    case Map.fetch(body, "value") do
      {:ok, machines} when is_list(machines) ->
        # A short page is the last one; there is no total to check against.
        next = if length(machines) == @page_size, do: skip + @page_size, else: nil
        {[machines], next}

      {:ok, _non_list} ->
        {[{:error, {:invalid_response, "value is not a list", body}}], nil}

      # A run deletes every device it did not see, so a response shape we do not
      # recognise has to fail loudly rather than read as an empty tenant.
      :error ->
        {[{:error, {:missing_key, "Expected key 'value' not found in response", body}}], nil}
    end
  end

  defp config, do: Portal.Config.fetch_env!(:portal, __MODULE__)
  defp endpoint, do: config()[:endpoint] || "https://api.security.microsoft.com"
  defp req_opts, do: config()[:req_opts] || []
end
