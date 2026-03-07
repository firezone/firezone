defmodule Portal.AzureCommunicationServices.APIClient do
  @moduledoc """
  Small client for ACS queued email delivery tracking.
  """

  alias Swoosh.Adapters.AzureCommunicationServices

  @api_version "2025-09-01"
  @weekdays {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
  @months {nil, "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
           "Dec"}

  def enabled? do
    secondary_config()[:adapter] == AzureCommunicationServices
  end

  def put_client_options(%Swoosh.Email{} = email) do
    req_opts = config()[:req_opts] || []

    if req_opts == [] do
      email
    else
      Swoosh.Email.put_private(email, :client_options, req_opts)
    end
  end

  def fetch_delivery_state(message_id) when is_binary(message_id) do
    with {:ok, operation} <- get_operation(message_id) do
      state =
        case operation["status"] do
          status when status in ["NotStarted", "Running"] -> :processing
          "Succeeded" -> :succeeded
          "Failed" -> :failed
          _ -> :processing
        end

      {:ok, %{state: state, operation: operation}}
    end
  end

  defp get_operation(message_id) do
    config = config()

    url =
      "#{config[:endpoint]}/emails/operations/#{URI.encode(message_id)}?api-version=#{@api_version}"

    headers = auth_headers(:get, url, "", config)

    case Req.get(url, [headers: headers] ++ req_opts()) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, stringify_keys(body)}

      {:ok, %Req.Response{} = response} ->
        {:error, response}

      {:error, _reason} = error ->
        error
    end
  end

  defp auth_headers(method, url, body, config) do
    case {config[:access_key], config[:auth]} do
      {access_key, nil} when is_binary(access_key) ->
        hmac_headers(method, body, url, access_key)

      {nil, auth} when not is_nil(auth) ->
        [{"Authorization", "Bearer #{resolve_auth(auth)}"}]

      {nil, nil} ->
        raise ArgumentError,
              "expected Portal.Mailer.Secondary to configure either :access_key or :auth"

      {_access_key, _auth} ->
        raise ArgumentError,
              "expected Portal.Mailer.Secondary to configure only one of :access_key or :auth"
    end
  end

  defp hmac_headers(method, body, url, access_key) do
    uri = URI.parse(url)
    host = request_host(uri)
    path_and_query = path_and_query(uri)

    content_hash = :crypto.hash(:sha256, body) |> Base.encode64()
    timestamp = format_rfc1123(DateTime.utc_now())

    string_to_sign =
      "#{String.upcase(to_string(method))}\n#{path_and_query}\n#{timestamp};#{host};#{content_hash}"

    key = Base.decode64!(access_key)
    signature = :crypto.mac(:hmac, :sha256, key, string_to_sign) |> Base.encode64()

    [
      {"x-ms-date", timestamp},
      {"x-ms-content-sha256", content_hash},
      {"host", host},
      {"Authorization",
       "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=#{signature}"}
    ]
  end

  defp format_rfc1123(datetime) do
    day_of_week = elem(@weekdays, Date.day_of_week(DateTime.to_date(datetime)) - 1)
    month = elem(@months, datetime.month)

    :io_lib.format("~s, ~2..0B ~s ~4B ~2..0B:~2..0B:~2..0B GMT", [
      day_of_week,
      datetime.day,
      month,
      datetime.year,
      datetime.hour,
      datetime.minute,
      datetime.second
    ])
    |> IO.iodata_to_binary()
  end

  defp request_host(%URI{} = uri) do
    case uri.host do
      nil ->
        raise ArgumentError,
              "expected ACS endpoint URL with host information, got: #{inspect(uri)}"

      host ->
        case uri.port do
          80 when uri.scheme == "http" -> host
          443 when uri.scheme == "https" -> host
          port when is_integer(port) -> "#{host}:#{port}"
          _ -> host
        end
    end
  end

  defp path_and_query(%URI{path: path, query: nil}), do: path
  defp path_and_query(%URI{path: path, query: query}), do: "#{path}?#{query}"

  defp resolve_auth(func) when is_function(func, 0), do: func.()
  defp resolve_auth({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: apply(m, f, a)
  defp resolve_auth(token) when is_binary(token), do: token

  defp resolve_auth(auth) do
    raise ArgumentError,
          "expected auth to be a string, a 0-arity function, or a {mod, fun, args} tuple, got: #{inspect(auth)}"
  end

  defp secondary_config do
    Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)
  end

  defp config do
    Keyword.merge(secondary_config(), Portal.Config.get_env(:portal, __MODULE__, []))
  end

  defp req_opts do
    config()[:req_opts] || []
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
