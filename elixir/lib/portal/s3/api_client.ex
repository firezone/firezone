defmodule Portal.S3.APIClient do
  @moduledoc """
  Amazon S3 adapter for log sink delivery.

  Each delivered chunk is written as one NDJSON object. Object keys are
  deterministic (stream, first event's date, seq range), so at-least-once
  redelivery overwrites the same object instead of duplicating events.

  Authentication is cross-account role assumption: the customer creates an
  IAM role trusting Firezone's AWS account, scoped by a per-sink ExternalId
  (confused-deputy protection). Each sync run assumes the role via STS and
  signs S3 requests with the temporary credentials.
  """

  @behaviour Portal.LogSinks.Adapter

  alias Portal.S3

  def aws_account_id do
    config() |> Keyword.fetch!(:aws_account_id)
  end

  # A trust policy missing the sts:ExternalId condition would let any
  # Firezone account's sink pointed at this role write into the customer's
  # bucket. A successful AssumeRole with a random external id proves the
  # condition is not enforced, so the sink refuses to deliver until it is.
  @impl true
  def prepare(%S3.LogSink{} = sink) do
    case assume_role(sink, Ecto.UUID.generate()) do
      {:ok, _credentials} ->
        {:error,
         {:config,
          "The IAM role's trust policy does not require this sink's External ID. Add the " <>
            "sts:ExternalId condition from the setup instructions to the role's trust policy."}}

      {:error, {:status, _denied}} ->
        case credentials(sink) do
          {:ok, _credentials} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def encode_event(_sink, _stream, {_time, event}) do
    JSON.encode!(event)
  end

  @impl true
  def join_batch(encoded_events) do
    IO.iodata_to_binary([Enum.intersperse(encoded_events, "\n"), "\n"])
  end

  @impl true
  def post_batch(%S3.LogSink{} = sink, body, meta) when is_binary(body) do
    case credentials(sink) do
      {:ok, credentials} ->
        put_object(sink, credentials, object_key(sink, meta), body)

      {:error, {:status, response}} ->
        {:ok, response}

      {:error, {:transport, exception}} ->
        {:error, exception}
    end
  end

  @impl true
  def interpret(_sink, %Req.Response{status: status}) when status in 200..299, do: :accepted
  def interpret(_sink, %Req.Response{status: 413}), do: :payload_too_large

  def interpret(_sink, %Req.Response{status: status}) when status in [429, 500, 502, 503, 504],
    do: :retriable

  def interpret(_sink, %Req.Response{}), do: :failed

  @impl true
  def format_status_error(%Req.Response{} = response) do
    case Req.Response.get_private(response, :portal_source, :s3) do
      :sts -> format_sts_error(response)
      :s3 -> format_s3_error(response)
    end
  end

  # Pdict-cached; each sync runs in its own Oban job process, so assumed
  # credentials never outlive a run.
  defp credentials(%S3.LogSink{} = sink) do
    case Process.get({__MODULE__, :credentials, sink.id}) do
      nil ->
        with {:ok, credentials} <- assume_role(sink, sink.external_id) do
          Process.put({__MODULE__, :credentials, sink.id}, credentials)
          {:ok, credentials}
        end

      credentials ->
        {:ok, credentials}
    end
  end

  defp assume_role(%S3.LogSink{} = sink, external_id) do
    url = "https://sts.#{sink.region}.amazonaws.com/"

    form =
      URI.encode_query(%{
        "Action" => "AssumeRole",
        "Version" => "2011-06-15",
        "RoleArn" => sink.role_arn,
        "RoleSessionName" => "firezone-#{sink.id}",
        "ExternalId" => external_id
      })

    headers =
      sign(
        firezone_credentials(),
        "sts",
        sink.region,
        "POST",
        url,
        [{"content-type", "application/x-www-form-urlencoded"}],
        form
      )

    result =
      req_opts()
      |> Req.new()
      |> Req.merge(url: url, headers: headers, redirect: false)
      |> Req.post(body: form)

    case result do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        parse_credentials(response_body)

      {:ok, %Req.Response{} = response} ->
        {:error, {:status, Req.Response.put_private(response, :portal_source, :sts)}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp parse_credentials(body) when is_binary(body) do
    with [_, access_key_id] <- Regex.run(~r|<AccessKeyId>([^<]+)</AccessKeyId>|, body),
         [_, secret_access_key] <-
           Regex.run(~r|<SecretAccessKey>([^<]+)</SecretAccessKey>|, body),
         [_, session_token] <- Regex.run(~r|<SessionToken>([^<]+)</SessionToken>|, body) do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token
       }}
    else
      nil -> {:error, {:transport, %RuntimeError{message: "Malformed STS AssumeRole response"}}}
    end
  end

  defp parse_credentials(_body) do
    {:error, {:transport, %RuntimeError{message: "Malformed STS AssumeRole response"}}}
  end

  defp put_object(sink, credentials, key, body) do
    url = "https://#{sink.bucket}.s3.#{sink.region}.amazonaws.com/#{encode_key(key)}"

    headers =
      sign(
        credentials,
        "s3",
        sink.region,
        "PUT",
        url,
        [{"content-type", "application/x-ndjson"}],
        body,
        uri_encode_path: false
      )

    req_opts()
    |> Req.new()
    |> Req.merge(url: url, headers: headers, redirect: false)
    |> Req.put(body: body)
  end

  defp object_key(sink, meta) do
    date =
      meta.first_time
      |> Kernel.*(1000)
      |> round()
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%Y/%m/%d")

    key = "#{meta.stream}/#{date}/#{meta.first_seq}-#{meta.last_seq}.ndjson"

    case sink.key_prefix do
      nil -> key
      prefix -> "#{prefix}/#{key}"
    end
  end

  defp encode_key(key) do
    URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))
  end

  # sign_v4 does not add a host header itself, so it must be in the signed
  # set; it is stripped afterwards because Req sets it from the URL.
  defp sign(credentials, service, region, method, url, headers, body, options \\ []) do
    headers =
      case credentials.session_token do
        nil -> headers
        session_token -> [{"x-amz-security-token", session_token} | headers]
      end

    headers = [{"host", URI.parse(url).host} | headers]

    :aws_signature.sign_v4(
      credentials.access_key_id,
      credentials.secret_access_key,
      region,
      service,
      :calendar.universal_time(),
      method,
      url,
      headers,
      body,
      options
    )
    |> Enum.reject(fn {name, _value} -> String.downcase(name) == "host" end)
  end

  defp firezone_credentials do
    config = config()
    access_key_id = Keyword.fetch!(config, :access_key_id)
    secret_access_key = Keyword.fetch!(config, :secret_access_key)

    if is_nil(access_key_id) or is_nil(secret_access_key) do
      raise "AWS credentials for Portal.S3.APIClient are not configured"
    end

    %{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      session_token: Keyword.get(config, :session_token)
    }
  end

  defp format_sts_error(%Req.Response{status: status, body: body}) do
    detail =
      case xml_error(body) do
        {code, message} -> "#{code}: #{message}"
        nil -> "HTTP #{status}"
      end

    "AWS STS returned #{detail} while assuming the role. Verify the role ARN, and that " <>
      "the role's trust policy allows Firezone's AWS account with this sink's External ID."
  end

  defp format_s3_error(%Req.Response{status: status} = response)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(response, "x-amz-bucket-region") do
      [actual_region | _] ->
        "Amazon S3 returned an HTTP #{status} redirect: the bucket is in #{actual_region}, " <>
          "not the configured region."

      [] ->
        "Amazon S3 returned an HTTP #{status} redirect. Check that the region matches " <>
          "the bucket's region."
    end
  end

  defp format_s3_error(%Req.Response{status: status, body: body}) do
    case xml_error(body) do
      {code, message} -> "Amazon S3 returned HTTP #{status} (#{code}): #{message}"
      nil -> "Amazon S3 returned HTTP #{status}"
    end
  end

  defp xml_error(body) when is_binary(body) do
    with [_, code] <- Regex.run(~r|<Code>([^<]+)</Code>|, body),
         [_, message] <- Regex.run(~r|<Message>([^<]+)</Message>|, body) do
      {code, message}
    else
      nil -> nil
    end
  end

  defp xml_error(_body), do: nil

  defp req_opts do
    config() |> Keyword.fetch!(:req_opts)
  end

  defp config do
    Portal.Config.fetch_env!(:portal, __MODULE__)
  end
end
