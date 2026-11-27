defmodule PortalAPI.DeviceCertificateController do
  @moduledoc """
  Issues a device certificate before the device connects. The device sends its token and a CSR
  for its key. The key binds to a device row only when the device connects with the
  certificate, so this changes no row.
  """
  use PortalAPI, :controller
  alias Portal.{Authentication, DeviceCA}
  alias PortalAPI.ProblemDetails

  # The vault answers in seconds, and a missing CA appears within minutes.
  @vault_retry_after_seconds 10
  @no_ca_retry_after_seconds 300

  def create(conn, params) do
    with {:ok, token} <- bearer_token(conn),
         :ok <- rate_limit(conn, :token, token_key(token)),
         {:ok, account_id} <- authenticate(conn, token),
         :ok <- rate_limit(conn, :account, "device_certificate:account:" <> account_id),
         {:ok, csr} <- decode_csr(params),
         {:ok, issued} <- DeviceCA.issue(account_id, csr) do
      json(conn, %{
        certificate: Portal.Crypto.X509.pem_encode(issued.certificate),
        ca_certificate: Portal.Crypto.X509.pem_encode(issued.ca_certificate)
      })
    else
      {:halt, conn} -> conn
      {:error, reason} -> error(conn, reason)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _other -> {:error, :missing_token}
    end
  end

  # Gateway and Client tokens share a format, so the token itself says which one it is.
  defp authenticate(conn, token) do
    if Authentication.gateway_token?(token) do
      case Authentication.verify_gateway_token(token) do
        {:ok, gateway_token} -> {:ok, gateway_token.account_id}
        {:error, _reason} -> {:error, :invalid_token}
      end
    else
      context = Authentication.Context.build(conn.remote_ip, user_agent(conn), conn.req_headers, :client)

      case Authentication.authenticate(token, context) do
        {:ok, subject} -> {:ok, subject.account.id}
        {:error, _reason} -> {:error, :invalid_token}
      end
    end
  end

  defp rate_limit(conn, scope, key) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    refill_rate = Keyword.fetch!(config, :"#{scope}_refill_rate")
    capacity = Keyword.fetch!(config, :"#{scope}_capacity")

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, 1) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:halt, ProblemDetails.rate_limited(conn, retry_after_ms)}
    end
  end

  # The token is a secret, so only a prefix of its hash names the bucket.
  defp token_key(token) do
    "device_certificate:token:" <> (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 32))
  end

  defp decode_csr(%{"csr" => csr}) when is_binary(csr) do
    case Base.decode64(csr) do
      {:ok, der} -> {:ok, der}
      :error -> {:error, :invalid_csr}
    end
  end

  defp decode_csr(_params), do: {:error, :invalid_csr}

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _rest] -> user_agent
      [] -> nil
    end
  end

  defp error(conn, :missing_token), do: ProblemDetails.send_with_code(conn, 401, :missing_token, "Missing token")
  defp error(conn, :invalid_token), do: ProblemDetails.send_with_code(conn, 401, :invalid_token, "Invalid token")

  defp error(conn, :invalid_csr),
    do: ProblemDetails.send_with_code(conn, 400, :invalid_csr, "The CSR is not a valid, signed request")

  defp error(conn, :unsupported_key),
    do: ProblemDetails.send_with_code(conn, 400, :unsupported_key, "The CSR must be for a P-256 key signed with SHA-256")

  defp error(conn, :throttled), do: ProblemDetails.rate_limited(conn, @vault_retry_after_seconds * 1000)
  defp error(conn, :no_key_storage), do: unavailable(conn, @no_ca_retry_after_seconds)
  defp error(conn, _reason), do: unavailable(conn, @vault_retry_after_seconds)

  defp unavailable(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> ProblemDetails.send_with_code(503, :device_certificate_unavailable, "Try again later", %{
      retry_after_seconds: retry_after
    })
  end
end
