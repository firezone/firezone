defmodule Portal.Authentication.Subject do
  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential

  @type actor :: %Portal.Actor{}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Portal.Account{},
          credential: Credential.t(),
          expires_at: DateTime.t(),
          context: Context.t(),
          attestation: map()
        }

  @enforce_keys [:actor, :account, :credential, :expires_at, :context]
  defstruct actor: nil,
            account: nil,
            credential: nil,
            expires_at: nil,
            context: nil,
            attestation: %{}

  @attestation_fields [
    last_attested_device_serial: :attested_device_serial,
    last_attested_device_uuid: :attested_device_uuid,
    last_attested_mdm_device_id: :attested_mdm_device_id,
    last_attested_cert_serial: :attested_cert_serial,
    last_attested_cert_fingerprint: :attested_cert_fingerprint,
    last_attested_cert_issuer: :attested_cert_issuer,
    last_attested_at: :attested_at
  ]

  @doc "Snapshots the device's last attestation, omitting absent fields."
  @spec with_device(t(), Portal.Device.t()) :: t()
  def with_device(%__MODULE__{} = subject, %Portal.Device{} = device) do
    attestation =
      for {field, key} <- @attestation_fields,
          value = Map.fetch!(device, field),
          not is_nil(value),
          into: %{} do
        {key, encode_attestation(key, value)}
      end

    %{subject | attestation: attestation}
  end

  # The issuer is a DER-encoded X.509 Name and must be safe for JSON logs.
  defp encode_attestation(:attested_cert_issuer, value), do: Base.encode64(value)
  defp encode_attestation(:attested_at, value), do: DateTime.to_iso8601(value)
  defp encode_attestation(_key, value), do: value

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = subject) do
    %{
      actor_id: subject.actor.id,
      actor_name: subject.actor.name,
      actor_email: subject.actor.email,
      actor_type: to_string(subject.actor.type),
      auth_provider_id: Credential.auth_provider_id(subject.credential),
      ip: format_ip(subject.context.remote_ip),
      ip_region: subject.context.remote_ip_location_region,
      ip_city: subject.context.remote_ip_location_city,
      ip_lat: subject.context.remote_ip_location_lat,
      ip_lon: subject.context.remote_ip_location_lon,
      user_agent: subject.context.user_agent
    }
    |> Map.merge(subject.attestation)
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: to_string(:inet.ntoa(ip))
end
