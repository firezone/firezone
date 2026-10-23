defmodule PortalAPI.Device.Channel.Credentials do
  @moduledoc """
  The secrets both ends of an authorized connection receive.

  One derivation serves every receiver, a gateway or a device reached through
  a pool: a WireGuard pre-shared key, ICE credentials for each side, and a
  flow-log ingest token for each side. Built once per authorization and
  handed to both the receiver's and the initiator's payload so the two sides
  always agree.
  """

  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject
  alias Portal.Device
  alias Portal.FlowLogToken

  @enforce_keys [
    :policy_authorization_id,
    :preshared_key,
    :ice_credentials,
    :initiator_ingest_token,
    :responder_ingest_token
  ]
  defstruct @enforce_keys

  @typedoc "One side's ICE username and password."
  @type ice_side :: %{username: String.t(), password: String.t()}

  @typedoc "A device and the public key it presented in this session."
  @type peer :: %{device: Device.t(), public_key: String.t()}

  @typedoc """
  What the ingest tokens attribute flow logs to: the authorization being
  created, the policy that granted it, the resource as `{id, name, address}`,
  whether that policy lets logs be uploaded, and when the authorization ends.
  """
  @type authorization :: %{
          id: Ecto.UUID.t(),
          policy_id: Ecto.UUID.t(),
          resource: {Ecto.UUID.t(), String.t(), String.t() | nil},
          uploads_enabled?: boolean(),
          expires_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          policy_authorization_id: Ecto.UUID.t(),
          preshared_key: String.t(),
          ice_credentials: %{initiator: ice_side(), receiver: ice_side()},
          initiator_ingest_token: String.t(),
          responder_ingest_token: String.t()
        }

  @doc "The secrets for `initiator` connecting to `receiver` under `authorization`."
  @spec generate(Subject.t(), peer(), peer(), authorization()) :: t()
  def generate(%Subject{} = subject, initiator, receiver, authorization) do
    {initiator_token, responder_token} =
      mint_ingest_tokens(subject, initiator.device, receiver.device, authorization)

    %__MODULE__{
      policy_authorization_id: authorization.id,
      preshared_key:
        Portal.Crypto.psk(
          initiator.device,
          initiator.public_key,
          receiver.device,
          receiver.public_key
        ),
      ice_credentials: ice_credentials(initiator, receiver),
      initiator_ingest_token: initiator_token,
      responder_ingest_token: responder_token
    }
  end

  # ICE credentials must stay the same for all connections between an initiator and a receiver as long
  # as they do not lose their state, so we can leverage their public keys, which are reset on each
  # restart of an initiator or a receiver.
  defp ice_credentials(initiator, receiver) do
    seed_hash =
      [initiator.device.id, initiator.public_key, receiver.device.id, receiver.public_key]
      |> Enum.join(":")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode32(case: :lower, padding: false)

    %{
      initiator: %{
        username: String.slice(seed_hash, 0..3),
        password: String.slice(seed_hash, 4..25)
      },
      receiver: %{
        username: String.slice(seed_hash, 26..29),
        password: String.slice(seed_hash, 30..52)
      }
    }
  end

  defp mint_ingest_tokens(
         %Subject{account: account, actor: actor, credential: credential} = subject,
         %Device{} = initiator,
         %Device{} = receiver,
         authorization
       ) do
    {os_name, os_version, client_version} =
      PortalAPI.Gateway.Views.Client.parse_user_agent(subject.context.user_agent)

    {resource_id, resource_name, resource_address} = authorization.resource

    attribution = %{
      # The authorization this batch of flow logs reports against. The ingest
      # endpoint rejects a request whose records mix more than one of these.
      "policy_authorization_id" => authorization.id,
      "policy_id" => authorization.policy_id,
      # The same pair as the authorization's initiating_device_id /
      # receiving_device_id. Shared by both tokens so either side's row names
      # the pair without a join; `role` says which of the two wrote it.
      "initiator_device_id" => initiator.id,
      "responder_device_id" => receiver.id,
      # Whether the authorizing policy allows this flow's logs to be uploaded
      # (policies.flow_log_uploads_enabled).
      # Devices honor it and the ingest endpoint enforces it, so the token can
      # always be minted while uploads stay policy-gated. The claim name is the
      # data-plane contract: connlib parses it as a required field.
      "uploads_enabled" => authorization.uploads_enabled?,
      "resource_id" => resource_id,
      "resource_name" => resource_name,
      "resource_address" => resource_address,
      # For client-to-client flows the receiving client's own owner is
      # deliberately not part of this snapshot.
      "initiator_actor_id" => actor.id,
      "initiator_actor_email" => actor.email,
      "initiator_actor_name" => actor.name,
      "initiator_auth_provider_id" => Credential.auth_provider_id(credential),
      # The authorization happens now; both tokens share the same authorized_at
      # so the two sides of the flow agree on the trusted flow_start floor.
      "authorized_at" => DateTime.to_iso8601(DateTime.utc_now()),
      # When this authorization expires (independent of the token's own exp,
      # which adds a reporting grace window on top). Stamped so the flow_log row
      # records the actual authorization lifetime.
      "authorization_expires_at" => DateTime.to_iso8601(authorization.expires_at),
      # The connecting client's device telemetry. It describes the initiating
      # client on both sides of the flow, so it is shared by both tokens and
      # named for the side it describes rather than for the reporter.
      "initiator_client_version" => client_version,
      "initiator_device_os_name" => os_name,
      "initiator_device_os_version" => os_version,
      "initiator_device_serial" => initiator.device_serial,
      "initiator_device_uuid" => initiator.device_uuid,
      "initiator_device_identifier_for_vendor" => initiator.identifier_for_vendor,
      "initiator_device_firebase_installation_id" => initiator.firebase_installation_id
    }

    expires_at = authorization.expires_at

    {
      FlowLogToken.mint(account, Map.put(attribution, "role", "initiator"), expires_at),
      FlowLogToken.mint(account, Map.put(attribution, "role", "responder"), expires_at)
    }
  end
end
