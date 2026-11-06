defmodule Portal.GoogleEndpoint.APIClient do
  @moduledoc """
  Client for the Cloud Identity Devices API, which serves the devices Google
  Endpoint Management knows.

  The API accepts only a service account with domain-wide delegation acting as
  a Workspace administrator. Firezone uses a service account of its own for
  this, separate from the directory sync one, so a customer delegates the
  read-only devices scope to it and nothing else.

  Devices are paged by token. Google leaves empty lists out of a response, so
  a page without `devices` is an empty page rather than an unknown shape.
  """

  @endpoint "https://cloudidentity.googleapis.com"
  @scope "https://www.googleapis.com/auth/cloud-identity.devices.readonly"
  @devices_path "/v1/devices"
  @page_size 100

  # Devices that at least one user has signed in on, which are the ones a
  # Client can run on. Company inventory nobody uses is left out.
  @view "USER_ASSIGNED_DEVICES"

  @doc "The OAuth scope a customer delegates to the service account."
  def scope, do: @scope

  @doc "The Devices API operation used for inventory."
  def devices_path, do: @devices_path

  @doc "The OAuth client ID of the service account, which a customer enters in domain-wide delegation."
  def client_id, do: config()[:client_id]

  @doc "Gets an access token that acts as the given Workspace administrator."
  def get_access_token(impersonation_email) do
    config = config()

    Portal.Google.APIClient.get_delegated_access_token(impersonation_email, @scope,
      email: config[:service_account_email],
      key: config[:service_account_key]
    )
  end

  @doc "Proves that the administrator's delegated token can list devices."
  def verify(impersonation_email) do
    with {:ok, access_token} <- get_access_token(impersonation_email),
         {:ok, _devices, _next_page_token} <- get_page(access_token, nil, 1) do
      :ok
    end
  end

  @doc "Streams every page of devices in the customer."
  def stream_devices(access_token) do
    Stream.resource(
      fn -> :first end,
      fn
        nil ->
          {:halt, nil}

        page_token ->
          case get_page(access_token, page_token, @page_size) do
            {:ok, devices, next_page_token} -> {[devices], next_page_token}
            {:error, reason} -> {[{:error, reason}], nil}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp get_page(access_token, page_token, page_size) do
    params = [customer: "customers/my_customer", view: @view, pageSize: page_size]
    params = if is_binary(page_token), do: Keyword.put(params, :pageToken, page_token), else: params

    case Req.get(
           (config()[:endpoint] || @endpoint) <> @devices_path,
           [
             headers: [{"Authorization", "Bearer #{access_token}"}, {"Accept", "application/json"}],
             params: params
           ] ++ req_opts()
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_page(body)
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # A run deletes devices it stops seeing, so a body that is not a page has to
  # fail rather than read as an empty customer.
  defp parse_page(body) when is_map(body) do
    with {:ok, devices} <- page_devices(body),
         {:ok, next_page_token} <- page_token(body) do
      {:ok, devices, next_page_token}
    end
  end

  defp parse_page(body), do: {:error, {:invalid_response, "expected a JSON object", body}}

  defp page_devices(%{"devices" => devices}) when is_list(devices), do: {:ok, devices}
  defp page_devices(%{"devices" => _} = body), do: {:error, {:invalid_response, "devices is not a list", body}}
  defp page_devices(_body), do: {:ok, []}

  defp page_token(%{"nextPageToken" => token}) when is_binary(token) and token != "", do: {:ok, token}
  defp page_token(%{"nextPageToken" => token}) when token in [nil, ""], do: {:ok, nil}
  defp page_token(%{"nextPageToken" => _} = body), do: {:error, {:invalid_response, "nextPageToken is invalid", body}}
  defp page_token(_body), do: {:ok, nil}

  defp config, do: Portal.Config.fetch_env!(:portal, __MODULE__)

  defp req_opts, do: config()[:req_opts] || []
end
