defmodule Portal.Intune.APIClient do
  @moduledoc """
  Microsoft Graph client for Intune managed-device inventory.
  """

  @graph_scope "https://graph.microsoft.com/.default"

  def get_access_token(tenant_id) do
    config = config()
    token_endpoint = "#{config[:token_base_url]}/#{tenant_id}/oauth2/v2.0/token"

    with {:ok, credential} <- client_credential(config) do
      body =
        %{
          "client_id" => config[:client_id],
          "scope" => @graph_scope,
          "grant_type" => "client_credentials"
        }
        |> Map.merge(credential)
        |> URI.encode_query()

      Req.post(
        token_endpoint,
        [
          headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
          body: body
        ] ++ req_opts()
      )
    end
  end

  def list_managed_devices(access_token) do
    query = URI.encode_query(%{"$top" => "1"})
    get("/v1.0/deviceManagement/managedDevices", query, access_token)
  end

  def stream_managed_devices(access_token) do
    query = URI.encode_query(%{"$top" => "999"})
    stream_pages("/v1.0/deviceManagement/managedDevices", query, access_token)
  end

  def test_connection(access_token) do
    case list_managed_devices(access_token) do
      {:ok, %Req.Response{status: 200, body: %{"value" => value}}} when is_list(value) -> :ok
      other -> other
    end
  end

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
       "client_assertion_type" =>
         "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
       "client_assertion" => assertion
     }}
  rescue
    exception -> {:error, exception}
  end

  defp stream_pages(path, query, access_token) do
    Stream.resource(
      fn -> {path, query} end,
      fn
        nil -> {:halt, nil}
        {current_path, current_query} -> fetch_page(current_path, current_query, access_token)
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(path, query, access_token) do
    case get(path, query, access_token) do
      {:ok, %Req.Response{status: 200, body: %{"value" => devices} = body}}
      when is_list(devices) ->
        {[devices], next_page(body)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {[{:error, {:invalid_response, body}}], nil}

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, reason} ->
        {[{:error, reason}], nil}
    end
  end

  defp next_page(%{"@odata.nextLink" => next_link}) when is_binary(next_link) do
    uri = URI.parse(next_link)
    {uri.path, uri.query || ""}
  end

  defp next_page(_body), do: nil

  defp get(path, query, access_token) do
    endpoint = config()[:endpoint] || "https://graph.microsoft.com"
    suffix = if query in [nil, ""], do: "", else: "?#{query}"

    Req.get(
      "#{endpoint}#{path}#{suffix}",
      [headers: [{"Authorization", "Bearer #{access_token}"}]] ++ req_opts()
    )
  end

  defp config, do: Portal.Config.fetch_env!(:portal, __MODULE__)
  defp req_opts, do: config()[:req_opts] || []
end
