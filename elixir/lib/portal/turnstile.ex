defmodule Portal.Turnstile do
  @moduledoc """
  Verifies Cloudflare Turnstile tokens submitted with the sign-up forms.

  https://developers.cloudflare.com/turnstile/get-started/server-side-validation/

  The check is skipped when no keys are configured, so development and self-hosted
  deployments keep working. When keys are configured, anything other than a
  successful verification rejects the sign-up, including Cloudflare being unreachable.
  """

  require Logger

  @max_token_length 2048

  def enabled?, do: not is_nil(site_key()) and not is_nil(secret_key())

  def site_key, do: key(:site_key)

  defp secret_key, do: key(:secret_key)

  defp key(name) do
    case config()[name] do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
      _other -> nil
    end
  end

  @spec verify(term(), :inet.ip_address() | nil) ::
          :ok | {:error, :missing_token | :invalid_token | :unavailable}
  def verify(token, remote_ip) do
    cond do
      not enabled?() -> :ok
      not is_binary(token) or token == "" -> {:error, :missing_token}
      byte_size(token) > @max_token_length -> {:error, :invalid_token}
      true -> siteverify(token, remote_ip)
    end
  end

  defp siteverify(token, remote_ip) do
    config = config()

    form =
      [secret: secret_key(), response: token]
      |> put_remote_ip(remote_ip)

    case Req.post(Keyword.fetch!(config, :endpoint), [form: form] ++ config[:req_opts]) do
      {:ok, %Req.Response{status: 200, body: %{"success" => true}}} ->
        :ok

      {:ok, %Req.Response{status: 200, body: %{"success" => false} = body}} ->
        Logger.info("Turnstile verification rejected", error_codes: inspect(body["error-codes"]))
        {:error, :invalid_token}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Turnstile verification unavailable", status: status)
        {:error, :unavailable}

      {:error, reason} ->
        Logger.warning("Turnstile verification unavailable", reason: inspect(reason))
        {:error, :unavailable}
    end
  end

  defp put_remote_ip(form, remote_ip) when is_tuple(remote_ip),
    do: Keyword.put(form, :remoteip, remote_ip |> :inet.ntoa() |> to_string())

  defp put_remote_ip(form, _remote_ip), do: form

  defp config, do: Portal.Config.get_env(:portal, __MODULE__, [])
end
