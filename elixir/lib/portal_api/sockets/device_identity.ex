defmodule PortalAPI.Sockets.DeviceIdentity do
  @moduledoc """
  The device identity that a Client or Gateway proves when it connects on the mTLS host with a
  certificate from its account's device CA. The hash of the certificate's key finds the device
  row, so the reported firezone_id never does.
  """
  alias Portal.DeviceCA

  # Mirrors the trust anchor upload bound and caps synthetic peer data before decoding.
  @max_cert_bytes 16_384

  @type t :: %{key_hash: binary(), not_after: DateTime.t(), ephemeral: boolean()}

  @doc """
  Returns the device identity of the connect, or nil when the connect is not on the mTLS host.

  `{:error, :not_device_ca_certificate}` means the certificate is from another CA, such as an
  MDM CA. `{:error, :device_certificate_invalid}` means the account's CA did not sign it, or it
  expired: the device gets a new certificate and connects again.
  """
  @spec verify(map(), Ecto.UUID.t(), map()) ::
          {:ok, t() | nil}
          | {:error, :not_device_ca_certificate | :device_certificate_invalid}
  def verify(connect_info, account_id, attrs) do
    with {:ok, der} <- presented_certificate(connect_info),
         {:ok, identity} <- DeviceCA.verify_certificate(account_id, der) do
      {:ok, Map.put(identity, :ephemeral, attrs["ephemeral"] in [true, "true"])}
    else
      {:error, :not_attestation_host} -> {:ok, nil}
      {:error, :invalid_device_certificate} -> {:error, :device_certificate_invalid}
      {:error, _reason} -> {:error, :not_device_ca_certificate}
    end
  end

  @doc """
  Returns the client certificate of a connect on the mTLS host. TLS has already proven that the
  device holds its key.
  """
  @spec presented_certificate(map()) ::
          {:ok, binary()}
          | {:error, :not_attestation_host | :no_certificate_presented | :invalid_certificate}
  def presented_certificate(connect_info) do
    case mtls_origin() do
      nil -> {:error, :not_attestation_host}
      origin -> with :ok <- validate_origin(connect_info, origin), do: certificate(connect_info)
    end
  end

  defp certificate(%{peer_data: %{ssl_cert: der}})
       when is_binary(der) and byte_size(der) > 0 and byte_size(der) <= @max_cert_bytes,
       do: {:ok, der}

  defp certificate(%{peer_data: %{ssl_cert: der}}) when is_binary(der),
    do: {:error, :invalid_certificate}

  defp certificate(_connect_info), do: {:error, :no_certificate_presented}

  defp mtls_origin do
    with url when is_binary(url) <- Portal.Config.get_env(:portal, :mtls_external_url),
         %URI{host: host, port: port} when is_binary(host) and is_integer(port) <- URI.parse(url) do
      {String.downcase(host), port}
    else
      _unconfigured -> nil
    end
  end

  defp validate_origin(%{uri: %URI{host: host, port: port}}, {mtls_host, mtls_port})
       when is_binary(host) and is_integer(port) do
    if {String.downcase(host), port} == {mtls_host, mtls_port} do
      :ok
    else
      {:error, :not_attestation_host}
    end
  end

  defp validate_origin(_connect_info, _mtls_origin), do: {:error, :not_attestation_host}
end
